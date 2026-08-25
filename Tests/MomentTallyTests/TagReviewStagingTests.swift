import Foundation
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// Staging semantics for the Label Review batch (#69): one pending change per
/// source scope, and key renames folding into the keys of changes that apply
/// after them.
@Suite struct TagReviewStagingTests {

    private func change(_ fromKey: String, _ fromValue: String?, to toKey: String,
                        value toValue: String? = nil,
                        spans: [Int]? = nil) -> StagedChange {
        StagedChange(fromKey: fromKey, fromValue: fromValue,
                     toKey: toKey, toValue: toValue, spanIDs: spans)
    }

    // MARK: adding — dedup by source scope

    @Test func restagingSameScopeReplaces() {
        // Dragging the same value twice (or onto a different key) must update
        // the earlier entry, not queue a second copy.
        var staged = [StagedChange]()
        staged = staged.adding(change("proj", "foo", to: "focus", value: "foo"))
        staged = staged.adding(change("proj", "foo", to: "music", value: "foo"))
        #expect(staged.count == 1)
        #expect(staged[0].toKey == "music")
    }

    @Test func restagingKeyRenameReplaces() {
        var staged = [StagedChange]()
        staged = staged.adding(change("focus", nil, to: "music"))
        staged = staged.adding(change("focus", nil, to: "jazz"))
        #expect(staged.count == 1)
        #expect(staged[0].toKey == "jazz")
    }

    @Test func subsetAndWholeValueAreDistinctScopes() {
        // A hand-picked subset move and a whole-value move describe different
        // span sets; both may be pending.
        var staged = [StagedChange]()
        staged = staged.adding(change("proj", "foo", to: "focus", value: "foo"))
        staged = staged.adding(change("proj", "foo", to: "music", value: "foo", spans: [1, 2]))
        #expect(staged.count == 2)
    }

    @Test func differentValuesAreDistinctScopes() {
        var staged = [StagedChange]()
        staged = staged.adding(change("proj", "foo", to: "focus", value: "foo"))
        staged = staged.adding(change("proj", "bar", to: "focus", value: "bar"))
        #expect(staged.count == 2)
    }

    @Test func keyRenameOntoOwnSpellingStagesNothing() {
        var staged = [StagedChange]()
        staged = staged.adding(change("focus", nil, to: " Focus "))
        #expect(staged.isEmpty)
    }

    // MARK: effectiveKey — folding staged/applied key renames

    @Test func effectiveKeyFollowsRename() {
        let staged = [change("focus", nil, to: "music")]
        #expect(staged.effectiveKey("focus") == "music")
        #expect(staged.effectiveKey("proj") == "proj")
    }

    @Test func effectiveKeyFollowsChains() {
        // a→b staged, then b→c: a's spans end at c, because the renames apply
        // in order.
        let staged = [change("a", nil, to: "b"), change("b", nil, to: "c")]
        #expect(staged.effectiveKey("a") == "c")
        #expect(staged.effectiveKey("b") == "c")
    }

    @Test func effectiveKeyMatchesApplyOrderForSwaps() {
        // a→b then b→a: a's spans land at b, then the second rename sweeps
        // *all* b spans (originals and arrivals) to a. Sequential folding
        // must agree with that.
        let staged = [change("a", nil, to: "b"), change("b", nil, to: "a")]
        #expect(staged.effectiveKey("a") == "a")
        #expect(staged.effectiveKey("b") == "a")
    }

    @Test func effectiveKeyIgnoresValueChanges() {
        // Value renames and moves don't respell keys.
        let staged = [change("focus", "bar", to: "music", value: "bar")]
        #expect(staged.effectiveKey("focus") == "focus")
    }

    @Test func effectiveKeyNormalizesRenameTargets() {
        // The rename target is user-typed; folding must land on the spelling
        // apply will actually create.
        let staged = [change("focus", nil, to: " My Music ")]
        #expect(staged.effectiveKey("focus") == "my-music")
    }

    // MARK: the #69 repro

    @Test func moveStagedAfterRenameFoldsToRenameTarget() {
        // Stage rename focus→music, then drop proj:foo onto the (still
        // displayed) focus row. The move must land on music, not recreate
        // focus — folding the pending renames into the later change's target.
        var staged = [StagedChange]()
        staged = staged.adding(change("focus", nil, to: "music"))
        staged = staged.adding(change("proj", "foo", to: "focus", value: "foo"))
        let move = staged[1]
        #expect(staged[..<1].effectiveKey(move.toKey) == "music")
    }
}

/// Label-set and quick-label rows following Mark Review rewrites (#177) —
/// `StagedChange.applied(to:toKey:)` is the one rewrite rule both stores
/// share, so a rename can't update sets and strand the quick labels.
@Suite struct StagedChangeRowRewriteTests {

    @Test func valueRenameRewritesMatchingRow() {
        let change = StagedChange(fromKey: "client", fromValue: "foo",
                                  toKey: "client", toValue: "Foo Co.", spanIDs: nil)
        let row = change.applied(to: TagRow(key: "client", value: "foo"), toKey: "client")
        #expect(row.key == "client" && row.value == "Foo Co.")
    }

    @Test func valueRenameLeavesOtherValuesAndKeys() {
        let change = StagedChange(fromKey: "client", fromValue: "foo",
                                  toKey: "client", toValue: "Foo Co.", spanIDs: nil)
        let otherValue = TagRow(key: "client", value: "bar")
        let otherKey = TagRow(key: "type", value: "foo")
        #expect(change.applied(to: otherValue, toKey: "client") == otherValue)
        #expect(change.applied(to: otherKey, toKey: "client") == otherKey)
    }

    @Test func keyRenameCarriesEveryValue() {
        // fromValue nil = the whole key; values ride along unchanged.
        let change = StagedChange(fromKey: "proj", fromValue: nil,
                                  toKey: "project", toValue: nil, spanIDs: nil)
        let row = change.applied(to: TagRow(key: "proj", value: "foo"), toKey: "project")
        #expect(row.key == "project" && row.value == "foo")
    }

    @Test func moveKeepingValueRewritesKeyOnly() {
        // toValue nil on a value move = each row keeps its value.
        let change = StagedChange(fromKey: "proj", fromValue: "foo",
                                  toKey: "focus", toValue: nil, spanIDs: nil)
        let row = change.applied(to: TagRow(key: "proj", value: "foo"), toKey: "focus")
        #expect(row.key == "focus" && row.value == "foo")
    }

    @Test func rowKeyMatchesAfterNormalization() {
        // Row keys are user-typed in the set editor; matching goes through
        // normalizeKey like every other comparison against scanned keys.
        let change = StagedChange(fromKey: "my-music", fromValue: "jazz",
                                  toKey: "my-music", toValue: "blues", spanIDs: nil)
        let row = change.applied(to: TagRow(key: " My Music ", value: "jazz"),
                                 toKey: "my-music")
        #expect(row.key == "my-music" && row.value == "blues")
    }

    @Test func rowIdentitySurvivesRewrite() {
        // TagRow ids are view-local focus anchors (#134); the rewrite must
        // not hand rows fresh identities.
        let original = TagRow(key: "client", value: "foo")
        let change = StagedChange(fromKey: "client", fromValue: "foo",
                                  toKey: "client", toValue: "Foo Co.", spanIDs: nil)
        #expect(change.applied(to: original, toKey: "client").id == original.id)
    }
}

/// Per-value colour overrides following Label Review rewrites (#69) — before
/// this, a staged rename silently dropped the value's colour.
@Suite struct ValueColorMigrationTests {

    private func colors(_ pairs: [(String, String, String)]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.map {
            (ValueColorKey.join($0.0, $0.1), $0.2)
        })
    }

    @Test func valueRenameCarriesOverride() {
        let migrated = ValueColorKey.migrating(
            colors([("focus", "bar", "#112233")]),
            fromKey: "focus", fromValue: "bar", toKey: "focus", toValue: "baz")
        #expect(migrated == colors([("focus", "baz", "#112233")]))
    }

    @Test func moveKeepingValueCarriesOverride() {
        // toValue nil = each span keeps its value, so the override lands on
        // the same value under the new key.
        let migrated = ValueColorKey.migrating(
            colors([("proj", "foo", "#112233")]),
            fromKey: "proj", fromValue: "foo", toKey: "music", toValue: nil)
        #expect(migrated == colors([("music", "foo", "#112233")]))
    }

    @Test func keyRenameCarriesEveryOverride() {
        let migrated = ValueColorKey.migrating(
            colors([("focus", "bar", "#112233"), ("focus", "baz", "#445566"),
                    ("proj", "foo", "#778899")]),
            fromKey: "focus", fromValue: nil, toKey: "music", toValue: nil)
        #expect(migrated == colors([("music", "bar", "#112233"),
                                    ("music", "baz", "#445566"),
                                    ("proj", "foo", "#778899")]))
    }

    @Test func existingDestinationOverrideWins() {
        // The destination's colour was chosen for that spelling; the source
        // override is dropped, not merged over it.
        let migrated = ValueColorKey.migrating(
            colors([("focus", "bar", "#112233"), ("music", "bar", "#445566")]),
            fromKey: "focus", fromValue: "bar", toKey: "music", toValue: nil)
        #expect(migrated == colors([("music", "bar", "#445566")]))
    }

    @Test func clearedValueDropsOverride() {
        // An empty target value has no override slot.
        let migrated = ValueColorKey.migrating(
            colors([("focus", "bar", "#112233")]),
            fromKey: "focus", fromValue: "bar", toKey: "focus", toValue: "")
        #expect(migrated.isEmpty)
    }

    @Test func untouchedOverridesStay() {
        let untouched = colors([("proj", "foo", "#112233")])
        let migrated = ValueColorKey.migrating(
            untouched,
            fromKey: "focus", fromValue: "bar", toKey: "music", toValue: nil)
        #expect(migrated == untouched)
    }
}
