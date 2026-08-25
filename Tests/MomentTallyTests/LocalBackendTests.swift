import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The local store, exercised end to end over real (in-memory or temp-file)
/// databases: every `Backend` operation, the date-range and paging behaviour,
/// tag set / value color persistence, and the one-time UserDefaults import.
@Suite struct LocalBackendTests {

    /// A fresh in-memory store. No legacy defaults unless a test passes some,
    /// so the import migration has nothing to import (the fresh-install path).
    private func makeBackend(defaults: UserDefaults? = nil,
                             pageSize: Int = 200) throws -> LocalBackend {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: defaults)
        backend.pageSize = pageSize
        return backend
    }

    /// An isolated UserDefaults suite, torn down by `withDefaults`' caller
    /// scope ending; never touches the standard domain.
    private func withDefaults<T>(_ populate: (UserDefaults) -> Void,
                                 _ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "LocalBackendTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        populate(defaults)
        return try body(defaults)
    }

    /// Whole-second dates so values survive the store's millisecond precision
    /// and compare with `==`.
    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    // MARK: Session

    @Test func currentUserIsAlwaysPresent() async throws {
        let backend = try makeBackend()
        let user = try await backend.currentUser()
        #expect(user != nil)   // the readiness probe: local mode has no login
    }

    // MARK: Timespan lifecycle

    @Test func startStopRoundTrip() async throws {
        let backend = try makeBackend()
        let labels = [SpanLabel(key: "repo", value: "moment-tally"),
                      SpanLabel(key: "work-type", value: "review")]
        let started = try await backend.startTimeSpan(start: date(1_000_000),
                                                      labels: labels, note: "")
        #expect(started.isRunning)
        #expect(started.labels == labels)

        // Running spans show up in timers(), and only there.
        let timers = try await backend.timers()
        #expect(timers.map(\.id) == [started.id])
        let beforeStop = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
        #expect(beforeStop.timeSpans.isEmpty)

        let stopped = try await backend.stopTimeSpan(id: started.id, end: date(1_003_600))
        #expect(stopped.end == date(1_003_600))
        #expect(stopped.labels == labels)   // labels survive the stop

        #expect(try await backend.timers().isEmpty)
        let afterStop = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
        #expect(afterStop.timeSpans.map(\.id) == [started.id])
    }

    @Test func updateRewritesEveryField() async throws {
        let backend = try makeBackend()
        let span = try await backend.startTimeSpan(
            start: date(1_000_000),
            labels: [SpanLabel(key: "old", value: "x")], note: "")

        let newLabels = [SpanLabel(key: "b", value: "2"), SpanLabel(key: "a", value: "1")]
        let updated = try await backend.updateTimeSpan(
            id: span.id, start: date(999_000), end: date(1_005_000),
            labels: newLabels, note: "edited")
        #expect(updated.start == date(999_000))
        #expect(updated.end == date(1_005_000))
        #expect(updated.note == "edited")
        // Replaced wholesale, preserving the order they were passed in.
        #expect(updated.labels == newLabels)

        // And that's what a re-fetch sees, not just the returned value.
        let fetched = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
        #expect(fetched.timeSpans.first?.labels == newLabels)
        #expect(fetched.timeSpans.first?.note == "edited")
    }

    @Test func removeDeletesSpanAndItsLabels() async throws {
        let backend = try makeBackend()
        let span = try await backend.startTimeSpan(
            start: date(1_000_000),
            labels: [SpanLabel(key: "repo", value: "moment-tally")], note: "")
        try await backend.removeTimeSpan(id: span.id)

        #expect(try await backend.timers().isEmpty)
        // The child rows went with it (ON DELETE CASCADE).
        let orphans = try await backend.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span_label")!
        }
        #expect(orphans == 0)
    }

    @Test func mutationsOnUnknownIdsThrow() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.updateTimeSpan(id: 99, start: self.date(0), end: nil,
                                                 labels: [], note: "")
        }
        await #expect(throws: (any Error).self) {
            _ = try await backend.stopTimeSpan(id: 99, end: self.date(0))
        }
        await #expect(throws: (any Error).self) {
            try await backend.removeTimeSpan(id: 99)
        }
    }

    // MARK: Label definitions

    @Test func labelDefinitionLifecycle() async throws {
        let backend = try makeBackend()
        try await backend.createLabelDefinition(key: "repo", color: "#112233")
        try await backend.createLabelDefinition(key: "area", color: "#445566")

        // Listed alphabetically by key.
        var definitions = try await backend.labelDefinitions()
        #expect(definitions == [LabelDefinition(key: "area", color: "#445566"),
                                LabelDefinition(key: "repo", color: "#112233")])

        try await backend.updateLabelDefinition(key: "repo", color: "#aabbcc")
        definitions = try await backend.labelDefinitions()
        #expect(definitions.first(where: { $0.key == "repo" })?.color == "#aabbcc")

        // The create/update split matches traggo: create rejects an existing
        // key, update rejects a missing one — callers already navigate this.
        await #expect(throws: (any Error).self) {
            try await backend.createLabelDefinition(key: "repo", color: "#000000")
        }
        await #expect(throws: (any Error).self) {
            try await backend.updateLabelDefinition(key: "missing", color: "#000000")
        }
    }

    /// The ensure path must be idempotent even though bare create is not:
    /// repeated ensures of the same key (an editor committing twice), and one
    /// ensure carrying the same new key on several tags, create it once and
    /// never surface the duplicate-insert error (#61).
    @Test func ensureLabelDefinitionsIsIdempotent() async throws {
        let backend = try makeBackend()
        try await backend.createLabelDefinition(key: "repo", color: "#112233")

        let tags = [SpanLabel(key: "repo", value: "moment-tally"),
                    SpanLabel(key: "work-type", value: "review"),
                    SpanLabel(key: "work-type", value: "debug")]
        let first = try await backend.ensureLabelDefinitions(for: tags,
                                                             defaultColor: "#445566")
        // Again, as a caller with a stale cache would.
        let second = try await backend.ensureLabelDefinitions(for: tags,
                                                              defaultColor: "#445566")

        // One definition per key; the pre-existing color is untouched.
        let expected = [LabelDefinition(key: "repo", color: "#112233"),
                        LabelDefinition(key: "work-type", color: "#445566")]
        #expect(first == expected)
        #expect(second == expected)
        #expect(try await backend.labelDefinitions() == expected)
    }

    // MARK: Date ranges

    @Test func timeSpansReturnsOverlapsOnly() async throws {
        let backend = try makeBackend()
        // A window of [2000, 3000] against spans placed around it.
        func finished(_ start: Int, _ end: Int) async throws -> TimeSpan {
            let span = try await backend.startTimeSpan(start: date(start), labels: [], note: "")
            return try await backend.stopTimeSpan(id: span.id, end: date(end))
        }
        _ = try await finished(500, 1_500)          // entirely before
        let straddlesFrom = try await finished(1_500, 2_500)
        let inside = try await finished(2_100, 2_200)
        let straddlesTo = try await finished(2_900, 3_500)
        let covers = try await finished(1_000, 4_000)
        _ = try await finished(3_500, 4_000)        // entirely after

        let page = try await backend.timeSpans(from: date(2_000), to: date(3_000), page: nil)
        // Overlap semantics (inclusive bounds), newest start first.
        #expect(page.timeSpans.map(\.id) ==
                [straddlesTo.id, inside.id, straddlesFrom.id, covers.id])
        #expect(page.nextPage == nil)
    }

    // MARK: Paging

    @Test func pageWalkIsExhaustiveNewestFirst() async throws {
        let backend = try makeBackend(pageSize: 2)
        var expected: [Int] = []
        for i in 0..<5 {
            let span = try await backend.startTimeSpan(start: date(1_000 + i * 100),
                                                       labels: [], note: "")
            _ = try await backend.stopTimeSpan(id: span.id, end: date(1_050 + i * 100))
            expected.append(span.id)
        }

        var walked: [Int] = []
        var token: PageToken?
        var pages = 0
        repeat {
            let page = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: token)
            walked += page.timeSpans.map(\.id)
            token = page.nextPage
            pages += 1
        } while token != nil
        #expect(pages == 3)                          // 2 + 2 + 1
        #expect(walked == expected.reversed())       // newest first, no dups
    }

    @Test func exactMultiplePageWalkMintsNoDeadToken() async throws {
        // 4 spans at page size 2: the second page is full AND final, and the
        // extra-row probe means it must not hand out a token to an empty page.
        let backend = try makeBackend(pageSize: 2)
        for i in 0..<4 {
            let span = try await backend.startTimeSpan(start: date(1_000 + i * 100),
                                                       labels: [], note: "")
            _ = try await backend.stopTimeSpan(id: span.id, end: date(1_050 + i * 100))
        }
        let first = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
        let second = try await backend.timeSpans(from: .distantPast, to: .distantFuture,
                                                 page: first.nextPage)
        #expect(second.timeSpans.count == 2)
        #expect(second.nextPage == nil)
    }

    @Test func pageWalkIsStableUnderConcurrentInserts() async throws {
        // Keyset pagination: rows created after the walk begins sort ahead of
        // the cursor (newer start) and must not shift or duplicate later pages.
        let backend = try makeBackend(pageSize: 2)
        for i in 0..<4 {
            let span = try await backend.startTimeSpan(start: date(1_000 + i * 100),
                                                       labels: [], note: "")
            _ = try await backend.stopTimeSpan(id: span.id, end: date(1_050 + i * 100))
        }
        let first = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: nil)

        // A brand-new span lands mid-walk, newer than everything.
        let late = try await backend.startTimeSpan(start: date(9_000), labels: [], note: "")
        _ = try await backend.stopTimeSpan(id: late.id, end: date(9_100))

        let second = try await backend.timeSpans(from: .distantPast, to: .distantFuture,
                                                 page: first.nextPage)
        let walked = (first.timeSpans + second.timeSpans).map(\.id)
        #expect(!walked.contains(late.id))
        #expect(Set(walked).count == walked.count)   // no duplicates either
    }

    @Test func foreignPageTokenActsAsFirstPage() async throws {
        let backend = try makeBackend()
        let span = try await backend.startTimeSpan(start: date(1_000), labels: [], note: "")
        _ = try await backend.stopTimeSpan(id: span.id, end: date(2_000))
        let page = try await backend.timeSpans(from: .distantPast, to: .distantFuture,
                                               page: PageToken(rawValue: "not ours"))
        #expect(page.timeSpans.map(\.id) == [span.id])
    }

    // MARK: Tag sets + value colors

    @Test func tagSetsSaveIsReplaceAll() async throws {
        let backend = try makeBackend()
        let a = TagSet(name: "A", tags: [TagRow(key: "k", value: "1"),
                                         TagRow(key: "k2", value: "2")])
        let b = TagSet(name: "B", tags: [TagRow(key: "x", value: "y")], symbolName: "hammer")
        try backend.saveTagSets([a, b])

        var loaded = try backend.loadTagSets()
        #expect(loaded.map(\.id) == [a.id, b.id])           // identity survives
        #expect(loaded[0].tags.map(\.key) == ["k", "k2"])   // member order too
        #expect(loaded[1].symbolName == "hammer")

        // Reorder and drop one: the snapshot fully replaces the old state...
        try backend.saveTagSets([b])
        loaded = try backend.loadTagSets()
        #expect(loaded.map(\.id) == [b.id])
        // ...including cascading away the removed set's member rows.
        let members = try await backend.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM label_set_member")!
        }
        #expect(members == 1)
    }

    @Test func cardColorRoundTripsWithoutDirtyingSync() async throws {
        let backend = try makeBackend()
        var set = TagSet(name: "Gaming", colorHex: "#aabbcc")
        try backend.saveTagSets([set])
        #expect(try backend.loadTagSets().first?.colorHex == "#aabbcc")

        // Mark the row clean (as a sync would), then recolor: the color
        // persists, but the row must stay clean — the card color is
        // local-only and never part of the sync payload.
        try await backend.dbQueue.write { db in
            try db.execute(sql: "UPDATE label_set SET dirty = 0")
        }
        set.colorHex = "#112233"
        try backend.saveTagSets([set])
        #expect(try backend.loadTagSets().first?.colorHex == "#112233")
        let dirty = try await backend.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT dirty FROM label_set")!
        }
        #expect(!dirty)

        // A rename alongside it still dirties the row as before.
        set.name = "Games"
        try backend.saveTagSets([set])
        let redirty = try await backend.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT dirty FROM label_set")!
        }
        #expect(redirty)
    }

    @Test func cardGradientRoundTripsWithoutDirtyingSync() async throws {
        // The per-card gradient (#226) is local-only like the card color:
        // it persists through save/load — including the unset (nil = on)
        // state — and flipping it alone must not dirty the row.
        let backend = try makeBackend()
        var flat = TagSet(name: "Flat", gradient: false)
        let unset = TagSet(name: "Unset")
        try backend.saveTagSets([flat, unset])
        let loaded = try backend.loadTagSets()
        #expect(loaded.first(where: { $0.name == "Flat" })?.gradient == false)
        #expect(loaded.first(where: { $0.name == "Unset" })?.gradient == nil)
        #expect(loaded.allSatisfy { $0.showsGradient == ($0.name == "Unset") })

        try await backend.dbQueue.write { db in
            try db.execute(sql: "UPDATE label_set SET dirty = 0")
        }
        flat.gradient = true
        try backend.saveTagSets([flat, unset])
        #expect(try backend.loadTagSets()
            .first(where: { $0.name == "Flat" })?.gradient == true)
        let dirtyCount = try await backend.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM label_set WHERE dirty = 1")!
        }
        #expect(dirtyCount == 0)
    }

    @Test func valueColorsRoundTripThroughRealColumns() throws {
        let backend = try makeBackend()
        // Values may contain ":" — the composite key's whole reason to exist.
        let colors = [ValueColorKey.join("repo", "traggo:menu"): "#112233",
                      ValueColorKey.join("area", "ui"): "#445566"]
        try backend.saveValueColors(colors)
        #expect(try backend.loadValueColors() == colors)

        // A malformed composite (no separator) is skipped, not corrupted.
        try backend.saveValueColors(["no-separator": "#000000"])
        #expect(try backend.loadValueColors().isEmpty)
    }

    // MARK: UserDefaults import

    @Test func importsLegacyPresetsAndValueColors() throws {
        let sets = [TagSet(name: "Deep Work", tags: [TagRow(key: "type", value: "programming")],
                           symbolName: "brain"),
                    TagSet(name: "Email", tags: [TagRow(key: "type", value: "email")])]
        let colors = [ValueColorKey.join("type", "a:b"): "#123456"]

        try withDefaults { defaults in
            defaults.set(try! JSONEncoder().encode(sets), forKey: "presets")
            defaults.set(colors, forKey: "valueColors")
        } _: { defaults in
            let backend = try makeBackend(defaults: defaults)
            let loaded = try backend.loadTagSets()
            #expect(loaded.map(\.id) == sets.map(\.id))
            #expect(loaded.map(\.name) == ["Deep Work", "Email"])
            #expect(loaded[0].symbolName == "brain")
            #expect(loaded[0].tags.map(\.value) == ["programming"])
            #expect(try backend.loadValueColors() == colors)
            // Copied, not moved: traggo mode still reads the legacy keys.
            #expect(defaults.data(forKey: "presets") != nil)
        }
    }

    @Test func freshDatabaseStartsWithNoTagSets() throws {
        // No legacy presets at all: nothing is seeded — onboarding is where
        // a fresh install's first label sets come from.
        let backend = try makeBackend()
        #expect(try backend.loadTagSets().isEmpty)
        #expect(try backend.loadValueColors().isEmpty)
    }

    @Test func importRunsExactlyOncePerDatabase() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBackendTests-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let original = [TagSet(name: "Original", tags: [TagRow(key: "k", value: "v")])]
        try withDefaults { defaults in
            defaults.set(try! JSONEncoder().encode(original), forKey: "presets")
        } _: { defaults in
            _ = try LocalBackend(DatabaseQueue(path: path), legacyDefaults: defaults)
        }

        // Reopening the same file with *different* legacy data must not
        // re-import (the migration already ran for this database).
        try withDefaults { defaults in
            let other = [TagSet(name: "Other", tags: [])]
            defaults.set(try! JSONEncoder().encode(other), forKey: "presets")
        } _: { defaults in
            let reopened = try LocalBackend(DatabaseQueue(path: path), legacyDefaults: defaults)
            let loaded = try reopened.loadTagSets()
            #expect(loaded.map(\.name) == ["Original"])
        }
    }

    // MARK: Quick labels (#92)

    /// The dirty flags of every label_set row, keyed by set id.
    private func setDirtyFlags(_ backend: LocalBackend) throws -> [String: Bool] {
        try backend.dbQueue.read { db in
            var flags: [String: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, dirty FROM label_set") {
                flags[row["id"]] = row["dirty"]
            }
            return flags
        }
    }

    @Test func quickLabelsImportFromUserDefaultsBlob() throws {
        let sets = [TagSet(name: "Deep Work"), TagSet(name: "Email")]
        let quick = [sets[0].id.uuidString: [TagRow(key: "type", value: "review"),
                                             TagRow(key: "type", value: "debugging")],
                     // A set deleted before the migration: its entry lingered
                     // in the blob and must be dropped, not imported.
                     UUID().uuidString: [TagRow(key: "ghost", value: "x")]]

        try withDefaults { defaults in
            defaults.set(try! JSONEncoder().encode(sets), forKey: "presets")
            defaults.set(try! JSONEncoder().encode(quick), forKey: "quickLabelsBySet")
        } _: { defaults in
            let backend = try makeBackend(defaults: defaults)
            let loaded = try backend.loadQuickLabels()
            #expect(Set(loaded.keys) == [sets[0].id.uuidString])
            #expect(loaded[sets[0].id.uuidString]?.map(\.value) == ["review", "debugging"])
            // Imported quick labels were never pushed: their set goes dirty
            // (it was born dirty anyway, but the migration must not rely on
            // that) while the untouched set's state is left alone.
            #expect(try setDirtyFlags(backend)[sets[0].id.uuidString] == true)
            // The v1 precedent: copied, not cleared.
            #expect(defaults.data(forKey: "quickLabelsBySet") != nil)
        }
    }

    @Test func saveQuickLabelsDirtiesOnlyChangedSets() throws {
        let backend = try makeBackend()
        let sets = [TagSet(name: "A"), TagSet(name: "B")]
        try backend.saveTagSets(sets)
        let aId = sets[0].id.uuidString
        let bId = sets[1].id.uuidString
        try backend.saveQuickLabels([aId: [TagRow(key: "type", value: "review")]])
        // Everything clean, as if a sync had pushed it all.
        try backend.dbQueue.write { db in
            try db.execute(sql: "UPDATE label_set SET dirty = 0")
        }

        // Same snapshot again: a no-op must not re-dirty anything.
        try backend.saveQuickLabels([aId: [TagRow(key: "type", value: "review")]])
        #expect(try setDirtyFlags(backend) == [aId: false, bId: false])

        // Editing one set's quick labels dirties that set only.
        try backend.saveQuickLabels([aId: [TagRow(key: "type", value: "debugging")]])
        #expect(try setDirtyFlags(backend) == [aId: true, bId: false])
        #expect(try backend.loadQuickLabels()[aId]?.map(\.value) == ["debugging"])

        // Entries for unknown sets are ignored, not persisted.
        try backend.saveQuickLabels([aId: [TagRow(key: "type", value: "debugging")],
                                     UUID().uuidString: [TagRow(key: "ghost", value: "x")]])
        #expect(Set(try backend.loadQuickLabels().keys) == [aId])
    }

    @Test func deletingASetCascadesItsQuickLabels() throws {
        let backend = try makeBackend()
        let sets = [TagSet(name: "A")]
        try backend.saveTagSets(sets)
        try backend.saveQuickLabels([sets[0].id.uuidString: [TagRow(key: "k", value: "v")]])

        try backend.saveTagSets([])
        #expect(try backend.loadQuickLabels().isEmpty)
    }
}
