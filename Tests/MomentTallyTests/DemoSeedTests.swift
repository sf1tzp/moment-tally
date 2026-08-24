import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The demo seeder (#39, renovated in #172): activation parsing,
/// determinism, the content fixtures every surface depends on, and
/// isolation from the real store.
@Suite struct DemoSeedTests {

    /// Gregorian + UTC so day layout (which offsets are weekends) doesn't
    /// depend on the machine running the tests.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month,
                                                day: day, hour: hour))!
    }

    /// Mid-week reference: the trailing month behind a Wednesday starts on a
    /// Monday, so the weekday-template cycle is easy to count by hand.
    private var wednesday: Date { date(2026, 7, 29, 10) }
    /// A second layout — Sunday evening — to prove the fixtures are
    /// launch-date-proof, not artifacts of one weekday arrangement.
    private var sunday: Date { date(2026, 8, 2, 21) }

    private func seed(now: Date) -> [DemoSeed.SeedSpan] {
        DemoSeed.spans(now: now, calendar: Self.calendar)
    }

    // MARK: Activation

    @Test func activationParsesEnvironmentAndArguments() {
        #expect(DemoMode.isActive(environment: ["MOMENTTALLY_DEMO": "1"], arguments: []))
        #expect(DemoMode.isActive(environment: ["MOMENTTALLY_DEMO": "true"], arguments: []))
        #expect(DemoMode.isActive(environment: [:], arguments: ["app", "--demo"]))
        #expect(!DemoMode.isActive(environment: ["MOMENTTALLY_DEMO": "0"], arguments: []))
        #expect(!DemoMode.isActive(environment: ["MOMENTTALLY_DEMO": ""], arguments: []))
        #expect(!DemoMode.isActive(environment: [:], arguments: ["app"]))
    }

    // MARK: Determinism

    @Test func seedIsDeterministicForAFixedReferenceDate() {
        #expect(seed(now: wednesday) == seed(now: wednesday))
    }

    @Test func writeRoundTripsTheGeneratedSeed() async throws {
        let backend = try LocalBackend(DatabaseQueue())
        try DemoSeed.write(to: backend, now: wednesday, calendar: Self.calendar)

        let finished = try await backend.timeSpans(from: .distantPast,
                                                   to: .distantFuture, page: nil).timeSpans
        let running = try await backend.timers()
        let stored = Set((finished + running).map {
            DemoSeed.SeedSpan(start: $0.start, end: $0.end, labels: $0.labels, note: $0.note)
        })
        #expect(stored == Set(seed(now: wednesday)))

        #expect(try backend.loadTagSets().map(\.name) == DemoSeed.tagSets.map(\.name))
        #expect(try await backend.labelDefinitions().count == DemoSeed.labelDefinitions.count)
        #expect(try backend.loadValueColors() == DemoSeed.valueColors)
    }

    // MARK: Content fixtures

    @Test func contentCountsForTheMidWeekLayout() {
        let spans = seed(now: wednesday)
        // The trailing month behind Wed 2026-07-29 runs Mon Jun 29 – Tue
        // Jul 28: 22 weekdays cycling A,B,C,D (A×6 + B×6 + D×5 at 7 spans,
        // C×5 at 6 spans = 149) + 8 weekend days alternating W1/W2
        // (4×3 + 4×4 = 28) + today (6).
        #expect(spans.count == 183)
        // Five cards since #189 culled the cast for screenshot presentation
        // (the shelved set survives as a comment in DemoSeed.tagSets).
        #expect(DemoSeed.tagSets.count == 5)
        #expect(Set(DemoSeed.tagSets.compactMap(\.symbolName)).count == 5)  // distinct symbols
        #expect(DemoSeed.labelDefinitions.count == 11)
        #expect(DemoSeed.valueColors.count == 33)
        // Notes on many spans, so Log and Calendar popovers have texture.
        #expect(spans.filter { !$0.note.isEmpty }.count >= 10)
    }

    @Test func fixturesHoldAcrossWeekLayouts() {
        for now in [wednesday, sunday] {
            let spans = seed(now: now)

            // One running span (the live menu-bar timer), started recently
            // enough to read as "just now" — #189 trimmed the second runner
            // (the multi-timer popover story) for cleaner screenshots,
            // leaving its slot as today's zero-length span.
            let running = spans.filter { $0.end == nil }
            #expect(running.count == 1)
            #expect(running.allSatisfy {
                $0.start > now.addingTimeInterval(-3600) && $0.start <= now
            })

            // Unlabelled ad-hoc spans (blank-timer story): one per D-day
            // plus one today.
            #expect(spans.filter(\.labels.isEmpty).count >= 5)

            // The proj/project drift for Mark Review — `proj: menu-shoot`
            // spans to move onto the canonical `project:` key (#172's capture).
            let labels = spans.flatMap(\.labels)
            #expect(labels.filter { $0.key == "proj" && $0.value == "menu-shoot" }
                .count >= 8)
            #expect(labels.contains { $0.key == "project" && $0.value == "menu-shoot" })

            // History's combined view needs real co-occurrence on all three
            // showcased pairings: type × project, type × client,
            // meeting × client.
            func cooccur(_ a: String, _ b: String) -> Bool {
                spans.contains { span in
                    span.labels.contains { $0.key == a } && span.labels.contains { $0.key == b }
                }
            }
            #expect(cooccur("type", "project"))
            #expect(cooccur("type", "client"))
            #expect(cooccur("meeting", "client"))

            // Every leisure chip value shows up in history, so the Launcher
            // hover video always has populated cards to point at.
            let values = { (key: String) in Set(labels.filter { $0.key == key }.map(\.value)) }
            #expect(values("recipe") == ["sourdough", "focaccia", "pad-thai"])
            #expect(values("activity") == ["bike", "run", "yoga"])
            #expect(values("book") == ["the-director", "crux", "the-wayfinder"])

            // At least one genuine overlap among *finished* spans (a
            // running span would overlap trivially).
            let finished = spans.filter { $0.end != nil }
            let overlaps = finished.contains { a in
                finished.contains { b in
                    a.start < b.start && b.start < a.end!
                }
            }
            #expect(overlaps)

            // Everything inside the trailing month, nothing in the future.
            #expect(spans.allSatisfy {
                $0.start >= now.addingTimeInterval(-31 * 86_400) && $0.start <= now
            })
            #expect(spans.allSatisfy { ($0.end ?? now) <= now })
        }
    }

    @Test func everySetCarriesItsQuickLabels() {
        for set in DemoSeed.tagSets {
            let quick = DemoSeed.quickLabels(forSetNamed: set.name)
            #expect(quick?.isEmpty == false, "\(set.name) has no quick labels")
        }
        // The design engagement carries the type trio; the full-service
        // photography set adds the meeting chips on top.
        let type = DemoSeed.quickLabels(forSetNamed: "Client Rebrand")!
        #expect(type.map(\.value) == ["design", "revisions", "invoicing"])
        #expect(type.allSatisfy { $0.key == "type" })
        #expect(DemoSeed.quickLabels(forSetNamed: "Wedding Shoot")!.count == 6)
        // The leisure sets are quick-labels-only: chips with no presets, and
        // a colorHex so their launcher cards aren't accent-grey.
        for name in ["Cooking", "Workout", "Reading"] {
            let set = DemoSeed.tagSets.first { $0.name == name }!
            #expect(set.tags.isEmpty)
            #expect(set.colorHex != nil)
        }
    }

    @Test func valuelessLabelsSeedTheFillInPerStartStory() {
        // Since the #189 cull the fill-in-per-start story (#149/#162) rides
        // on one card: Client Rebrand's value-less `deliverable:` —
        // quick-starting it opens the editor with the empty value focused.
        let rows = DemoSeed.tagSets.first { $0.name == "Client Rebrand" }!.tags
        #expect(rows.contains { $0.key == "deliverable" && $0.value.isEmpty })
    }

    @Test func valueColorsDifferentiateTheProjects() {
        let colors = DemoSeed.valueColors
        let menu = colors[ValueColorKey.join("project", "menu-shoot")]
        let wedding = colors[ValueColorKey.join("project", "wedding-shoot")]
        #expect(menu != nil && wedding != nil && menu != wedding)
        // The drifted spelling matches the canonical one, so the mistake
        // reads in Mark Review rather than on every pill.
        #expect(colors[ValueColorKey.join("proj", "menu-shoot")] == menu)
    }

    // MARK: Isolation from the real store

    @Test func demoDatabaseLivesBesideButNeverAtTheRealPath() throws {
        let demo = try LocalBackend.demoDatabaseURL()
        let real = try LocalBackend.defaultDatabaseURL()
        #expect(demo.lastPathComponent == "demo.sqlite")
        #expect(demo != real)
        #expect(demo.deletingLastPathComponent() == real.deletingLastPathComponent())
    }

    @Test func demoStoreIsRebuiltFromScratchAtItsOwnPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoSeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.sqlite")

        // Seeding writes only to the path it was given.
        let first = try LocalBackend.demo(at: url, now: wednesday, calendar: Self.calendar)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { $0.hasPrefix("demo.sqlite") })

        // A "previous session" leaves extra data behind...
        _ = try await first.startTimeSpan(start: wednesday, labels: [], note: "stale")

        // ...and the next demo launch starts over from exactly the seed.
        let second = try LocalBackend.demo(at: url, now: wednesday, calendar: Self.calendar)
        let count = try await second.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span")!
        }
        #expect(count == seed(now: wednesday).count)

        // The demo never imports the user's presets (legacyDefaults is nil):
        // its tag sets are the demo's, nothing legacy.
        #expect(try second.loadTagSets().map(\.name) == DemoSeed.tagSets.map(\.name))
    }
}
