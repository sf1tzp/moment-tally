import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The combined History view's span→pair mapping (#109), strict semantics:
/// every span lands in exactly one "outer · inner" cell, or in none at all.
@Suite struct CombinedGroupingTests {

    private func pair(_ tags: [SpanLabel],
                      outer: GroupingDefinition,
                      inner: GroupingDefinition) -> String? {
        HistoryModel.pairLabel(tags: tags, outer: outer, inner: inner)
    }

    // MARK: Key × key

    @Test func keyByKeyPairsTheTwoValues() {
        #expect(pair([SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "type", value: "coding")],
                     outer: .key("proj"), inner: .key("type"))
                == "infra · coding")
    }

    @Test func missingEitherDimensionExcludesTheSpan() {
        // Strict: only spans carrying BOTH dimensions count, which is why the
        // combined donut's total can undershoot the split view's left donut.
        let projOnly = [SpanLabel(key: "proj", value: "infra")]
        #expect(pair(projOnly, outer: .key("proj"), inner: .key("type")) == nil)
        #expect(pair(projOnly, outer: .key("type"), inner: .key("proj")) == nil)
        #expect(pair([], outer: .key("proj"), inner: .key("type")) == nil)
    }

    @Test func emptyValuesReadNoValue() {
        // An empty tag value still matches its dimension, shown as the same
        // "(no value)" series the split donuts use.
        #expect(pair([SpanLabel(key: "proj", value: ""),
                      SpanLabel(key: "type", value: "coding")],
                     outer: .key("proj"), inner: .key("type"))
                == "(no value) · coding")
        #expect(pair([SpanLabel(key: "proj", value: ""),
                      SpanLabel(key: "type", value: "")],
                     outer: .key("proj"), inner: .key("type"))
                == "(no value) · (no value)")
    }

    // MARK: Tag-set dimensions

    @Test func tagSetMemberFormatsAsKeyValue() {
        // Same "key: value" (or bare-key) series labels as the split donuts.
        #expect(pair([SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "type", value: "coding")],
                     outer: .key("proj"),
                     inner: .tagSetMembers([SpanLabel(key: "type", value: "coding")]))
                == "infra · type: coding")
        #expect(pair([SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "billable", value: "")],
                     outer: .key("proj"),
                     inner: .tagSetMembers([SpanLabel(key: "billable", value: "")]))
                == "infra · billable")
    }

    @Test func multiMatchCountsOnlyTheFirstStoredMember() {
        // A span matching several members of a tag-set dimension counts only
        // toward the first match in the set's stored label order — no
        // cross-product, so sums never exceed tracked time.
        let members = [SpanLabel(key: "focus", value: "deep"),
                       SpanLabel(key: "proj", value: "infra")]
        let tags = [SpanLabel(key: "proj", value: "infra"),
                    SpanLabel(key: "focus", value: "deep"),
                    SpanLabel(key: "type", value: "coding")]
        #expect(pair(tags, outer: .tagSetMembers(members), inner: .key("type"))
                == "focus: deep · coding")
        // Stored order decides, not the span's tag order.
        #expect(pair(tags.reversed(), outer: .tagSetMembers(members), inner: .key("type"))
                == "focus: deep · coding")
    }

    @Test func spanMatchingNoMemberIsExcluded() {
        let members = [SpanLabel(key: "focus", value: "deep")]
        #expect(pair([SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "focus", value: "shallow")],
                     outer: .key("proj"), inner: .tagSetMembers(members))
                == nil)
    }

    @Test func tagSetByTagSetTakesFirstOfEach() {
        let outers = [SpanLabel(key: "proj", value: "infra"),
                      SpanLabel(key: "proj", value: "app")]
        let inners = [SpanLabel(key: "type", value: "review"),
                      SpanLabel(key: "type", value: "coding")]
        let tags = [SpanLabel(key: "proj", value: "app"),
                    SpanLabel(key: "proj", value: "infra"),
                    SpanLabel(key: "type", value: "coding"),
                    SpanLabel(key: "type", value: "review")]
        #expect(pair(tags, outer: .tagSetMembers(outers), inner: .tagSetMembers(inners))
                == "proj: infra · type: review")
    }
}
