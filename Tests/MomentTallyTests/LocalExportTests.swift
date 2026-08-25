import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The JSON export (#57): document contents, ordering, the schema version,
/// and the ISO 8601 wire format a future import will rely on.
@Suite struct LocalExportTests {

    private func makeBackend() throws -> LocalBackend {
        try LocalBackend(DatabaseQueue())
    }

    /// Whole-second dates, as in LocalBackendTests: they survive the store's
    /// millisecond precision and compare with `==`.
    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    @Test func exportsEverythingTheStoreOwns() async throws {
        let backend = try makeBackend()
        try await backend.createLabelDefinition(key: "repo", color: "#ff0000")
        try await backend.createLabelDefinition(key: "type", color: "#00ff00")
        let finished = try await backend.startTimeSpan(
            start: date(1_000_000),
            labels: [SpanLabel(key: "repo", value: "moment-tally"),
                     SpanLabel(key: "type", value: "review")],
            note: "reviewing")
        _ = try await backend.stopTimeSpan(id: finished.id, end: date(1_003_600))
        let running = try await backend.startTimeSpan(
            start: date(1_010_000), labels: [], note: "")
        try backend.saveValueColors([ValueColorKey.join("repo", "moment-tally"): "#123456"])
        let set = TagSet(name: "Review", tags: [TagRow(key: "repo", value: "moment-tally")],
                         symbolName: "hammer")
        // A quick-labels-only set: no members, card color of its own.
        let gaming = TagSet(name: "Gaming", symbolName: "gamecontroller",
                            colorHex: "#aabbcc")
        try backend.saveTagSets([set, gaming])

        let export = try backend.exportData(at: date(2_000_000))

        #expect(export.schemaVersion == LocalExport.currentSchemaVersion)
        #expect(export.exportedAt == date(2_000_000))

        // Spans in start order, labels inline in insertion order, the
        // running span with a nil end.
        #expect(export.timeSpans == [
            LocalExport.Span(id: Int64(finished.id), start: date(1_000_000),
                             end: date(1_003_600), note: "reviewing",
                             labels: [.init(key: "repo", value: "moment-tally"),
                                      .init(key: "type", value: "review")]),
            LocalExport.Span(id: Int64(running.id), start: date(1_010_000),
                             end: nil, note: "", labels: []),
        ])

        #expect(export.labelDefinitions == [
            LabelDefinition(key: "repo", color: "#ff0000"),
            LabelDefinition(key: "type", color: "#00ff00"),
        ])
        #expect(export.valueColors == [
            LocalExport.ValueColor(key: "repo", value: "moment-tally", color: "#123456"),
        ])
        #expect(export.labelSets == [
            LocalExport.LabelSet(id: set.id.uuidString, name: "Review",
                                 symbol: "hammer", color: nil,
                                 labels: [.init(key: "repo", value: "moment-tally")]),
            LocalExport.LabelSet(id: gaming.id.uuidString, name: "Gaming",
                                 symbol: "gamecontroller", color: "#aabbcc",
                                 labels: []),
        ])
    }

    @Test func freshStoreExportsNothing() throws {
        let backend = try makeBackend()
        let export = try backend.exportData()
        #expect(export.timeSpans.isEmpty)
        #expect(export.labelDefinitions.isEmpty)
        #expect(export.valueColors.isEmpty)
        #expect(export.labelSets.isEmpty)
    }

    @Test func jsonCarriesTopLevelSchemaVersion() async throws {
        let backend = try makeBackend()
        let data = try backend.exportJSON()
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["timeSpans"] is [Any])
        #expect(object["labelDefinitions"] is [Any])
        #expect(object["valueColors"] is [Any])
        #expect(object["labelSets"] is [Any])
    }

    @Test func datesAreISO8601WithOffset() async throws {
        let backend = try makeBackend()
        _ = try await backend.startTimeSpan(start: date(1_000_000), labels: [], note: "")
        let json = try #require(String(data: backend.exportJSON(), encoding: .utf8))
        // Fractional seconds plus an explicit offset ("Z" or ±hh:mm) on every
        // serialised date.
        let dates = json.matches(of: #/"start" : "([^"]*)"/#).map { String($0.1) }
        #expect(dates.count == 1)
        let pattern = #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})/#
        #expect(dates.allSatisfy { $0.wholeMatch(of: pattern) != nil })
    }

    /// The whole point of the schema-versioned format: what the encoder
    /// writes, the (future importer's) decoder reads back verbatim.
    @Test func documentRoundTripsThroughJSON() async throws {
        let backend = try makeBackend()
        try await backend.createLabelDefinition(key: "repo", color: "#ff0000")
        _ = try await backend.startTimeSpan(
            start: date(1_000_000),
            labels: [SpanLabel(key: "repo", value: "a/b:c")], note: "notes\n🙂")

        let export = try backend.exportData(at: date(2_000_000))
        let data = try LocalExport.encoder().encode(export)
        let decoded = try LocalExport.decoder().decode(LocalExport.self, from: data)
        #expect(decoded == export)
    }
}
