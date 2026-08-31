import Foundation
import Testing
@testable import MomentTallyCore

/// Tag input normalisation: whatever the editors let you type, the labels
/// that reach a mutation carry no surrounding whitespace in key or value.
@Suite struct TagSetTests {

    @Test func normalizeKeyLowercasesAndDashes() {
        #expect(normalizeKey("My Key") == "my-key")
    }

    @Test func decodesSavesThatPredateCardColor() throws {
        // Sets persisted before `colorHex` existed (the legacy UserDefaults
        // JSON the v1 import reads) must keep decoding, colorless.
        let json = """
        {"id":"6F1D2C3B-0000-0000-0000-000000000000","name":"Gaming",
         "tags":[{"id":"6F1D2C3B-0000-0000-0000-000000000001","key":"","value":""}]}
        """
        let set = try JSONDecoder().decode(TagSet.self, from: Data(json.utf8))
        #expect(set.name == "Gaming")
        #expect(set.colorHex == nil)
    }

    @Test func normalizeKeyTrimsBeforeDashing() {
        // Surrounding whitespace is a typo, not intent — " repo " must not
        // become "-repo-".
        #expect(normalizeKey(" repo ") == "repo")
        #expect(normalizeKey("  My Key ") == "my-key")
    }

    @Test func labelsTrimValues() {
        let rows = [TagRow(key: "repo", value: " foo "),
                    TagRow(key: " client ", value: "acme corp")]
        #expect(rows.labels == [SpanLabel(key: "repo", value: "foo"),
                                SpanLabel(key: "client", value: "acme corp")])
    }

    @Test func labelsDropKeylessRows() {
        let rows = [TagRow(key: "  ", value: "orphan"),
                    TagRow(key: "a", value: "b")]
        #expect(rows.labels == [SpanLabel(key: "a", value: "b")])
    }

    // MARK: Reordering (moveRow(_:onto:))

    @Test func moveRowDownTakesTargetsPlace() {
        var rows = [TagRow(key: "a"), TagRow(key: "b"), TagRow(key: "c")]
        let moved = rows.moveRow(rows[0].id, onto: rows[2].id)
        #expect(moved)
        #expect(rows.map(\.key) == ["b", "c", "a"])
    }

    @Test func moveRowUpTakesTargetsPlace() {
        var rows = [TagRow(key: "a"), TagRow(key: "b"), TagRow(key: "c")]
        let moved = rows.moveRow(rows[2].id, onto: rows[0].id)
        #expect(moved)
        #expect(rows.map(\.key) == ["c", "a", "b"])
    }

    @Test func moveRowOntoItselfIsAcceptedNoOp() {
        var rows = [TagRow(key: "a"), TagRow(key: "b")]
        let moved = rows.moveRow(rows[0].id, onto: rows[0].id)
        #expect(moved)
        #expect(rows.map(\.key) == ["a", "b"])
    }

    @Test func moveRowFromAnotherListBouncesBack() {
        // A labels row dropped on a quick-labels row (or vice versa) carries
        // an id the receiving list doesn't know — refuse, change nothing.
        var rows = [TagRow(key: "a"), TagRow(key: "b")]
        let moved = rows.moveRow(UUID(), onto: rows[1].id)
        #expect(!moved)
        #expect(rows.map(\.key) == ["a", "b"])
    }

    // MARK: Quick labels (labels(applying:))

    @Test func applyingQuickLabelAppends() {
        let set = TagSet(tags: [TagRow(key: "repo", value: "a"),
                                TagRow(key: "feat", value: "b")])
        #expect(set.labels(applying: TagRow(key: "type", value: "coding"))
                == [SpanLabel(key: "repo", value: "a"),
                    SpanLabel(key: "feat", value: "b"),
                    SpanLabel(key: "type", value: "coding")])
    }

    @Test func applyingQuickLabelReplacesSameKey() {
        // A quick label hones the set, so its value wins over the set's
        // baked-in value for the same key — no double `type:`.
        let set = TagSet(tags: [TagRow(key: "repo", value: "a"),
                                TagRow(key: "type", value: "programming")])
        #expect(set.labels(applying: TagRow(key: "type", value: "review"))
                == [SpanLabel(key: "repo", value: "a"),
                    SpanLabel(key: "type", value: "review")])
    }

    @Test func applyingQuickLabelMatchesNormalisedKeys() {
        // "Type " and "type" are the same key once normalised.
        let set = TagSet(tags: [TagRow(key: "Type ", value: "programming")])
        #expect(set.labels(applying: TagRow(key: "type", value: "review"))
                == [SpanLabel(key: "type", value: "review")])
    }

    // MARK: Running-span matching (matches(spanLabels:quicks:))

    @Test func matchesOwnLabels() {
        let set = TagSet(tags: [TagRow(key: "repo", value: "a")])
        #expect(set.matches(spanLabels: [SpanLabel(key: "repo", value: "a")],
                            quicks: []))
        // Order-insensitive, like every other set comparison.
        let two = TagSet(tags: [TagRow(key: "repo", value: "a"),
                                TagRow(key: "client", value: "b")])
        #expect(two.matches(spanLabels: [SpanLabel(key: "client", value: "b"),
                                         SpanLabel(key: "repo", value: "a")],
                            quicks: []))
    }

    @Test func matchesQuickStartOverMarklessSet() {
        // The launcher regression's simplest shape (#207): a set with no
        // marks of its own, started via a quick-mark chip — the span carries
        // only the quick mark, and must still read as the set running.
        let set = TagSet(name: "Workout")
        let quick = TagRow(key: "kind", value: "run")
        #expect(set.matches(spanLabels: [SpanLabel(key: "kind", value: "run")],
                            quicks: [quick]))
        #expect(!set.matches(spanLabels: [SpanLabel(key: "kind", value: "run")],
                             quicks: []))
    }

    @Test func matchesQuickStartReplacingBakedInValue() {
        // The honing shape: `+review` over the set's baked-in
        // `type: programming` — the span's differing value for the same key
        // must still match through the quick.
        let set = TagSet(tags: [TagRow(key: "repo", value: "a"),
                                TagRow(key: "type", value: "programming")])
        let quick = TagRow(key: "type", value: "review")
        #expect(set.matches(spanLabels: [SpanLabel(key: "repo", value: "a"),
                                         SpanLabel(key: "type", value: "review")],
                            quicks: [quick]))
    }

    @Test func valuedQuickRequiresItsExactValue() {
        // A quick's declared value is exact — an unrelated value for the same
        // key is some other timer, not this set's quick start.
        let set = TagSet(tags: [TagRow(key: "repo", value: "a")])
        let quick = TagRow(key: "type", value: "review")
        #expect(!set.matches(spanLabels: [SpanLabel(key: "repo", value: "a"),
                                          SpanLabel(key: "type", value: "qa")],
                             quicks: [quick]))
    }

    @Test func valueLessQuickMatchesAnyFilledValue() {
        // `issue:` starts blank and the editor fills the value moments later
        // (#149) — the card must stay lit through and after that fill-in.
        let set = TagSet(tags: [TagRow(key: "repo", value: "a")])
        let quick = TagRow(key: "issue", value: "")
        #expect(set.matches(spanLabels: [SpanLabel(key: "repo", value: "a"),
                                         SpanLabel(key: "issue", value: "")],
                            quicks: [quick]))
        #expect(set.matches(spanLabels: [SpanLabel(key: "repo", value: "a"),
                                         SpanLabel(key: "issue", value: "123")],
                            quicks: [quick]))
        // But not without the set's own marks under it.
        #expect(!set.matches(spanLabels: [SpanLabel(key: "issue", value: "123")],
                             quicks: [quick]))
    }

    @Test func bakedValueLessMarkIsAFillInSlotToo() {
        // A set can bake the fill-in slot in (`issue:` as a set mark, not a
        // quick) — the card must stay lit after the editor fills the value.
        let set = TagSet(tags: [TagRow(key: "project", value: "mt"),
                                TagRow(key: "issue", value: "")])
        #expect(set.matches(spanLabels: [SpanLabel(key: "project", value: "mt"),
                                         SpanLabel(key: "issue", value: "141")],
                            quicks: []))
        // The slot's key must still be present on the span.
        #expect(!set.matches(spanLabels: [SpanLabel(key: "project", value: "mt")],
                             quicks: []))
    }

    @Test func extraOrMissingMarksDoNotMatch() {
        // A span carrying more (or fewer) marks than any startable labelling
        // is a different timer — a superset must not dim the card.
        let set = TagSet(tags: [TagRow(key: "repo", value: "a")])
        let quick = TagRow(key: "type", value: "review")
        #expect(!set.matches(spanLabels: [SpanLabel(key: "repo", value: "a"),
                                          SpanLabel(key: "type", value: "review"),
                                          SpanLabel(key: "extra", value: "x")],
                             quicks: [quick]))
        #expect(!set.matches(spanLabels: [], quicks: [quick]))
    }
}
