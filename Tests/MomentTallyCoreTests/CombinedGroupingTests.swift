// Apple-only (#85): these tests exercise the app layer in MomentTallyKit,
// which (like the SwiftUI beneath it) does not exist on Linux.
#if canImport(MomentTallyKit)
import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// An `across` breakdown's span→pair mapping (#109, per row since #291),
/// strict semantics: every span lands in exactly one "outer · inner" cell,
/// or in none at all.
@Suite struct CombinedGroupingTests {

    private func pair(_ tags: [SpanLabel], outer: String, inner: String) -> String? {
        HistoryModel.pairLabel(tags: tags, outer: outer, inner: inner)
    }

    @Test func keyByKeyPairsTheTwoValues() {
        #expect(pair([SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "type", value: "coding")],
                     outer: "proj", inner: "type")
                == "infra · coding")
    }

    @Test func missingEitherDimensionExcludesTheSpan() {
        // Strict: only spans carrying BOTH keys count, which is why an
        // across donut's total can undershoot the plain donut of its key.
        let projOnly = [SpanLabel(key: "proj", value: "infra")]
        #expect(pair(projOnly, outer: "proj", inner: "type") == nil)
        #expect(pair(projOnly, outer: "type", inner: "proj") == nil)
        #expect(pair([], outer: "proj", inner: "type") == nil)
    }

    @Test func emptyValuesReadNoValue() {
        // An empty tag value still matches its key, shown as the same
        // "(no value)" series the plain donuts use.
        #expect(pair([SpanLabel(key: "proj", value: ""),
                      SpanLabel(key: "type", value: "coding")],
                     outer: "proj", inner: "type")
                == "(no value) · coding")
        #expect(pair([SpanLabel(key: "proj", value: ""),
                      SpanLabel(key: "type", value: "")],
                     outer: "proj", inner: "type")
                == "(no value) · (no value)")
    }

    @Test func plainSeriesLabelIsTheValue() {
        let tags = [SpanLabel(key: "proj", value: "infra"), SpanLabel(key: "flag", value: "")]
        #expect(HistoryModel.seriesLabel(tags: tags, key: "proj") == "infra")
        #expect(HistoryModel.seriesLabel(tags: tags, key: "flag") == "(no value)")
        #expect(HistoryModel.seriesLabel(tags: tags, key: "type") == nil)
    }
}

/// The History tab's persisted setup (#291) round-trips through JSON with
/// the row ids intact, and an absent range stays absent.
@Suite struct HistorySetupTests {
    @Test func roundTripsRowsAndRange() throws {
        let rows = [ChartBreakdown(key: "type"),
                    ChartBreakdown(key: "project", across: "client")]
        let setup = HistorySetup(range: .days30, rows: rows)
        let data = try JSONEncoder().encode(setup)
        #expect(try JSONDecoder().decode(HistorySetup.self, from: data) == setup)
    }

    @Test func weekRangeEncodesAsAbsent() throws {
        let setup = HistorySetup(range: nil, rows: [ChartBreakdown(key: "type")])
        let data = try JSONEncoder().encode(setup)
        let decoded = try JSONDecoder().decode(HistorySetup.self, from: data)
        #expect(decoded.range == nil)
        #expect(decoded.rows.first?.across == nil)
    }
}
#endif
