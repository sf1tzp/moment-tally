import Foundation
import Testing
@testable import MomentTallyCore

/// The CLI's export filter (#80): selector parsing, the include/exclude
/// semantics, local-day bounds with overlap, and the filter block a partial
/// document records.
@Suite struct ExportFilterTests {

    /// A fixed-zone calendar so "local day" is deterministic wherever the
    /// tests run.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A UTC instant from components, matching the `utc` calendar.
    private func instant(_ year: Int, _ month: Int, _ day: Int,
                         _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day,
                                      hour: hour, minute: minute))!
    }

    private func span(id: Int64 = 1, start: Date, end: Date?,
                      labels: [(String, String)] = [], note: String = "") -> LocalExport.Span {
        LocalExport.Span(id: id, start: start, end: end, note: note,
                         labels: labels.map { LocalExport.Label(key: $0.0, value: $0.1) })
    }

    private func document(_ spans: [LocalExport.Span]) -> LocalExport {
        LocalExport(exportedAt: instant(2026, 8, 1), timeSpans: spans,
                    labelDefinitions: [LabelDefinition(key: "repo", color: "#ff0000")],
                    valueColors: [], labelSets: [])
    }

    // MARK: Selector parsing

    @Test func selectorsSplitOnTheFirstColon() throws {
        let pair = try #require(LabelSelector("repo:sfi/moment-tally"))
        #expect(pair.key == "repo")
        #expect(pair.value == "sfi/moment-tally")
        #expect(pair.rawValue == "repo:sfi/moment-tally")

        // Values may contain ":" — only the first one splits.
        let colons = try #require(LabelSelector("url:https://example.com"))
        #expect(colons.key == "url")
        #expect(colons.value == "https://example.com")

        let bare = try #require(LabelSelector("repo"))
        #expect(bare.key == "repo")
        #expect(bare.value == nil)
        #expect(bare.rawValue == "repo")

        #expect(LabelSelector("") == nil)
        #expect(LabelSelector(":value") == nil)
    }

    @Test func selectorMatching() throws {
        let labels = [LocalExport.Label(key: "repo", value: "app"),
                      LocalExport.Label(key: "type", value: "review")]
        #expect(try #require(LabelSelector("repo:app")).matches(labels))
        #expect(!(try #require(LabelSelector("repo:server")).matches(labels)))
        // Bare key: any value counts.
        #expect(try #require(LabelSelector("repo")).matches(labels))
        #expect(!(try #require(LabelSelector("project")).matches(labels)))
    }

    @Test func filterArgumentsAreValidated() {
        #expect(throws: ExportFilter.ParseError.self) {
            try ExportFilter(fromDay: "yesterday", calendar: utc)
        }
        #expect(throws: ExportFilter.ParseError.self) {
            try ExportFilter(fromDay: "2026-07-31", toDay: "2026-07-01", calendar: utc)
        }
        #expect(throws: ExportFilter.ParseError.self) {
            try ExportFilter(include: [":oops"], calendar: utc)
        }
    }

    // MARK: Date bounds

    @Test func dayBoundsKeepSpansByOverlap() throws {
        let filter = try ExportFilter(fromDay: "2026-07-01", toDay: "2026-07-31",
                                      calendar: utc)
        // Entirely before / after the range.
        #expect(!filter.keeps(span(start: instant(2026, 6, 30, 9),
                                   end: instant(2026, 6, 30, 17))))
        #expect(!filter.keeps(span(start: instant(2026, 8, 1, 0, 30),
                                   end: instant(2026, 8, 1, 1))))
        // Wholly inside, including the last day (--to is inclusive).
        #expect(filter.keeps(span(start: instant(2026, 7, 31, 22),
                                  end: instant(2026, 7, 31, 23))))
        // Crossing midnight into the range counts as overlap.
        #expect(filter.keeps(span(start: instant(2026, 6, 30, 23),
                                  end: instant(2026, 7, 1, 1))))
        // Crossing midnight out of the range too.
        #expect(filter.keeps(span(start: instant(2026, 7, 31, 23),
                                  end: instant(2026, 8, 1, 1))))
        // A running span never ends before the range...
        #expect(filter.keeps(span(start: instant(2026, 6, 1), end: nil)))
        // ...but one started after it still misses.
        #expect(!filter.keeps(span(start: instant(2026, 8, 2), end: nil)))
    }

    @Test func openEndedBounds() throws {
        let from = try ExportFilter(fromDay: "2026-07-01", calendar: utc)
        #expect(from.keeps(span(start: instant(2027, 1, 1), end: instant(2027, 1, 2))))
        #expect(!from.keeps(span(start: instant(2026, 6, 1), end: instant(2026, 6, 2))))

        let to = try ExportFilter(toDay: "2026-07-31", calendar: utc)
        #expect(to.keeps(span(start: instant(2020, 1, 1), end: instant(2020, 1, 2))))
        #expect(!to.keeps(span(start: instant(2026, 8, 1), end: nil)))
    }

    // MARK: Selector semantics

    @Test func everyIncludeMustMatchAndExcludeWins() throws {
        let both = span(start: instant(2026, 7, 2), end: instant(2026, 7, 2, 1),
                        labels: [("repo", "app"), ("type", "review")])
        let one = span(start: instant(2026, 7, 2), end: instant(2026, 7, 2, 1),
                       labels: [("repo", "app")])

        let and = try ExportFilter(include: ["repo:app", "type:review"], calendar: utc)
        #expect(and.keeps(both))
        #expect(!and.keeps(one))

        // A span matching an include *and* an exclude is dropped.
        let conflict = try ExportFilter(include: ["repo:app"], exclude: ["type:review"],
                                        calendar: utc)
        #expect(conflict.keeps(one))
        #expect(!conflict.keeps(both))

        // Bare-key exclude: drop anything carrying the key at all.
        let bare = try ExportFilter(exclude: ["type"], calendar: utc)
        #expect(bare.keeps(one))
        #expect(!bare.keeps(both))
    }

    // MARK: The filtered document

    @Test func emptyFilterLeavesTheDocumentAlone() throws {
        let original = document([span(start: instant(2026, 7, 2), end: nil)])
        let filtered = original.filtered(try ExportFilter(calendar: utc))
        #expect(filtered == original)
        #expect(filtered.filter == nil)
    }

    @Test func filteredDocumentRecordsTheRequestVerbatim() throws {
        let original = document([
            span(id: 1, start: instant(2026, 7, 2), end: instant(2026, 7, 2, 1),
                 labels: [("repo", "app")]),
            span(id: 2, start: instant(2026, 7, 2), end: instant(2026, 7, 2, 1),
                 labels: [("repo", "server")]),
            span(id: 3, start: instant(2026, 9, 1), end: nil,
                 labels: [("repo", "app")]),
        ])
        let filtered = original.filtered(try ExportFilter(
            fromDay: "2026-07-01", toDay: "2026-07-31",
            include: ["repo:app"], calendar: utc))

        #expect(filtered.timeSpans.map(\.id) == [1])
        // Configuration passes through: the document stays valid importer input.
        #expect(filtered.labelDefinitions == original.labelDefinitions)
        #expect(filtered.filter == LocalExport.Filter(
            from: "2026-07-01", to: "2026-07-31", include: ["repo:app"], exclude: nil))
    }

    /// Full exports must not change shape: the filter key appears only on
    /// partial documents, and both kinds survive the decoder round trip.
    @Test func filterKeyOnlyOnPartialDocuments() throws {
        let original = document([span(start: instant(2026, 7, 2), end: nil,
                                      labels: [("repo", "app")])])
        let fullJSON = String(decoding: try LocalExport.encoder().encode(original),
                              as: UTF8.self)
        #expect(!fullJSON.contains("\"filter\""))

        let partial = original.filtered(try ExportFilter(exclude: ["repo"], calendar: utc))
        #expect(partial.timeSpans.isEmpty)
        let partialJSON = String(decoding: try LocalExport.encoder().encode(partial),
                                 as: UTF8.self)
        #expect(partialJSON.contains("\"filter\""))
        #expect(partialJSON.contains("\"exclude\""))
        #expect(!partialJSON.contains("\"include\""))   // nil arrays are omitted

        let decoded = try LocalExport.decoder().decode(
            LocalExport.self, from: Data(partialJSON.utf8))
        #expect(decoded == partial)
    }
}
