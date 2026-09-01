// Apple-only (#85): these tests exercise the app layer in MomentTallyKit,
// which (like the SwiftUI beneath it) does not exist on Linux.
#if canImport(MomentTallyKit)
import Foundation
import GRDB
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The traggo importer's engine, exercised with a `LocalBackend` on both ends
/// — the whole point of the source being `any Backend` is that the paged walk,
/// running-span handling, and origin-id dedupe need no network to test.
@Suite struct HistoryImporterTests {

    private let origin = "https://traggo.lofi"

    /// A fresh in-memory store. A small page size on a *source* forces the
    /// import to actually walk pages.
    private func makeBackend(pageSize: Int = 200) throws -> LocalBackend {
        let backend = try LocalBackend(DatabaseQueue())
        backend.pageSize = pageSize
        return backend
    }

    /// Whole-second dates so values survive the store's millisecond precision
    /// and compare with `==`.
    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    @discardableResult
    private func finished(_ backend: LocalBackend, start: Int, end: Int,
                          labels: [SpanLabel] = [], note: String = "") async throws -> TimeSpan {
        let span = try await backend.startTimeSpan(start: date(start), labels: labels, note: note)
        _ = try await backend.updateTimeSpan(id: span.id, start: date(start), end: date(end),
                                             labels: labels, note: note)
        return TimeSpan(id: span.id, start: date(start), end: date(end),
                        note: note, labels: labels)
    }

    /// Everything a backend holds (finished walk + running), as id-agnostic
    /// fingerprints — local ids differ between source and destination by
    /// design, so equality is over the data that should survive the trip.
    private func fingerprints(_ backend: LocalBackend) async throws -> Set<String> {
        var spans: [TimeSpan] = []
        var token: PageToken?
        repeat {
            let page = try await backend.timeSpans(from: .distantPast, to: .distantFuture, page: token)
            spans += page.timeSpans
            token = page.nextPage
        } while token != nil
        spans += try await backend.timers()
        let prints = spans.map { span in
            "\(span.start.timeIntervalSince1970)|\(span.end?.timeIntervalSince1970 ?? -1)"
                + "|\(span.note)|\(span.labels.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        }
        #expect(Set(prints).count == prints.count)   // fingerprints must be distinct
        return Set(prints)
    }

    /// A source with enough history to page: 5 finished spans (with labels and
    /// notes), 2 running ones, and colored definitions.
    private func makeSource() async throws -> LocalBackend {
        let source = try makeBackend(pageSize: 2)
        try await source.createLabelDefinition(key: "repo", color: "#112233")
        try await source.createLabelDefinition(key: "work-type", color: "#445566")
        for i in 0..<5 {
            try await finished(source, start: 1_000 + i * 100, end: 1_050 + i * 100,
                               labels: [SpanLabel(key: "repo", value: "moment-tally-\(i)")],
                               note: "finished \(i)")
        }
        _ = try await source.startTimeSpan(start: date(2_000),
                                           labels: [SpanLabel(key: "work-type", value: "review")],
                                           note: "running a")
        _ = try await source.startTimeSpan(start: date(2_100), labels: [], note: "running b")
        return source
    }

    // MARK: Full walk

    @Test func fullWalkImportsFinishedAndRunningSpans() async throws {
        let source = try await makeSource()
        let destination = try makeBackend()

        var progress: [Int] = []
        let importer = HistoryImporter(source: source, destination: destination, origin: origin)
        let summary = try await importer.run { progress.append($0) }

        #expect(summary.spansInserted == 7)
        #expect(summary.spansUpdated == 0)
        #expect(summary.runningSpans == 2)
        #expect(summary.definitionsCreated == 2)

        // Every span made the trip intact — dates, notes, labels, and the
        // running/finished distinction (imported running spans still run).
        #expect(try await fingerprints(destination) == fingerprints(source))
        let running = try await destination.timers()
        #expect(running.map(\.note).sorted() == ["running a", "running b"])

        // Definitions came over with their key colors.
        #expect(try await destination.labelDefinitions() ==
                [LabelDefinition(key: "repo", color: "#112233"),
                 LabelDefinition(key: "work-type", color: "#445566")])

        // Progress climbed monotonically to the total (2 running + 3 pages).
        #expect(progress == progress.sorted())
        #expect(progress.last == 7)
        #expect(progress.count >= 4)
    }

    // MARK: Idempotency

    @Test func reRunUpsertsInsteadOfDuplicating() async throws {
        let source = try await makeSource()
        let destination = try makeBackend()
        let importer = HistoryImporter(source: source, destination: destination, origin: origin)

        _ = try await importer.run()
        let after1 = try await fingerprints(destination)
        let summary = try await importer.run()

        // Second run touched every span but created none.
        #expect(summary.spansInserted == 0)
        #expect(summary.spansUpdated == 7)
        #expect(summary.definitionsCreated == 0)
        #expect(summary.definitionsRecolored == 0)
        #expect(try await fingerprints(destination) == after1)
    }

    @Test func reRunPicksUpSourceChanges() async throws {
        let source = try await makeSource()
        let destination = try makeBackend()
        let importer = HistoryImporter(source: source, destination: destination, origin: origin)
        _ = try await importer.run()

        // The source moves on: a running span finishes, a note gets edited.
        let stopped = try await source.timers().first { $0.note == "running a" }!
        _ = try await source.stopTimeSpan(id: stopped.id, end: date(3_000))
        source.pageSize = 200   // one page for the lookup...
        let edited = try await source.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
            .timeSpans.first { $0.note == "finished 0" }!
        source.pageSize = 2     // ...but the re-import still walks pages
        _ = try await source.updateTimeSpan(id: edited.id, start: edited.start, end: edited.end,
                                            labels: [SpanLabel(key: "repo", value: "renamed")],
                                            note: "edited")

        _ = try await importer.run()
        #expect(try await fingerprints(destination) == fingerprints(source))
        // The previously running span is now finished locally too.
        #expect(try await destination.timers().map(\.note) == ["running b"])
    }

    @Test func localSpansSurviveImportUntouched() async throws {
        let source = try await makeSource()
        let destination = try makeBackend()
        // A span born local before the import — note that its local id (1)
        // collides numerically with a source id, which must not matter.
        let local = try await finished(destination, start: 5_000, end: 5_100,
                                       labels: [SpanLabel(key: "local", value: "only")],
                                       note: "born local")

        let importer = HistoryImporter(source: source, destination: destination, origin: origin)
        _ = try await importer.run()
        _ = try await importer.run()

        let prints = try await fingerprints(destination)
        #expect(prints.count == 8)                       // 7 imported + 1 local
        #expect(prints.contains { $0.contains("born local") })
        let fetched = try await destination.timeSpans(from: .distantPast, to: .distantFuture, page: nil)
            .timeSpans.first { $0.note == "born local" }
        #expect(fetched?.labels == local.labels)
    }

    @Test func distinctOriginsKeepSeparateIdNamespaces() async throws {
        // Two servers can both have a span id 1; the origin string keeps their
        // mappings apart, so importing both yields both.
        let sourceA = try makeBackend()
        _ = try await finished(sourceA, start: 1_000, end: 1_100, note: "from a")
        let sourceB = try makeBackend()
        _ = try await finished(sourceB, start: 2_000, end: 2_100, note: "from b")
        let destination = try makeBackend()

        _ = try await HistoryImporter(source: sourceA, destination: destination,
                                      origin: "https://a.lofi").run()
        _ = try await HistoryImporter(source: sourceB, destination: destination,
                                      origin: "https://b.lofi").run()
        // And a re-run of each stays idempotent within its own namespace.
        let again = try await HistoryImporter(source: sourceA, destination: destination,
                                              origin: "https://a.lofi").run()
        #expect(again.spansInserted == 0)
        #expect(try await fingerprints(destination).count == 2)
    }

    @Test func originMappingSurvivesDatabaseReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryImporterTests-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = try await makeSource()
        do {
            let destination = try LocalBackend(DatabaseQueue(path: path))
            _ = try await HistoryImporter(source: source, destination: destination,
                                          origin: origin).run()
        }

        // A later session re-imports into the same file: the mapping persisted,
        // so nothing duplicates.
        let reopened = try LocalBackend(DatabaseQueue(path: path))
        let summary = try await HistoryImporter(source: source, destination: reopened,
                                                origin: origin).run()
        #expect(summary.spansInserted == 0)
        #expect(summary.spansUpdated == 7)
        #expect(try await fingerprints(reopened) == fingerprints(source))
    }

    // MARK: Definition color policy

    @Test func importedDefinitionColorWinsOverLocal() async throws {
        let source = try makeBackend()
        try await source.createLabelDefinition(key: "repo", color: "#server1")
        try await source.createLabelDefinition(key: "area", color: "#server2")
        try await source.createLabelDefinition(key: "same", color: "#both00")

        let destination = try makeBackend()
        // "repo" exists locally (the auto-created default blue, typically);
        // "same" matches already; "local-only" is untouched by the import.
        try await destination.createLabelDefinition(key: "repo", color: "#2196f3")
        try await destination.createLabelDefinition(key: "same", color: "#both00")
        try await destination.createLabelDefinition(key: "local-only", color: "#abcdef")

        let summary = try await HistoryImporter(source: source, destination: destination,
                                                origin: origin).run()
        #expect(summary.definitionsCreated == 1)     // area
        #expect(summary.definitionsRecolored == 1)   // repo; "same" not counted

        #expect(try await destination.labelDefinitions() ==
                [LabelDefinition(key: "area", color: "#server2"),
                 LabelDefinition(key: "local-only", color: "#abcdef"),
                 LabelDefinition(key: "repo", color: "#server1"),
                 LabelDefinition(key: "same", color: "#both00")])
    }
}
#endif
