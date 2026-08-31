import Foundation
import MomentTallyCore
import Observation

/// Usage of one value under a key: how many scanned timespans carry it and
/// how much tracked time they add up to.
package struct ValueStat: Identifiable {
    package var id: String { value }
    package let value: String
    package let count: Int
    package let seconds: TimeInterval

    package init(value: String, count: Int, seconds: TimeInterval) {
        self.value = value
        self.count = count
        self.seconds = seconds
    }
}

/// One tag key with its value cardinality — the review's unit of display.
package struct KeyStat: Identifiable {
    package var id: String { key }
    package let key: String
    package let values: [ValueStat]   // most-used first

    package init(key: String, values: [ValueStat]) {
        self.key = key
        self.values = values
    }

    package var spanCount: Int { values.reduce(0) { $0 + $1.count } }
    package var seconds: TimeInterval { values.reduce(0) { $0 + $1.seconds } }
}

/// One pending tag rewrite, staged for review in the Approve Changes pane.
/// The shape covers every cleanup the tab offers: rename a value (same key,
/// new value), rename a key (`fromValue` and `toValue` nil — values ride
/// along), move a value under another key, and move just a subset of its
/// instances (`spanIDs` non-nil).
package struct StagedChange: Identifiable {
    package var id = UUID()
    package var fromKey: String       // mutable: key renames applied earlier in a batch fold in
    package let fromValue: String?    // nil = every value under the key
    package var toKey: String
    package var toValue: String?      // nil = keep each span's value; editable while staged
    package let spanIDs: [Int]?       // nil = every scanned match

    package init(id: UUID = UUID(), fromKey: String, fromValue: String?,
                 toKey: String, toValue: String?, spanIDs: [Int]?) {
        self.id = id
        self.fromKey = fromKey
        self.fromValue = fromValue
        self.toKey = toKey
        self.toValue = toValue
        self.spanIDs = spanIDs
    }

    package var isKeyRename: Bool { fromValue == nil }

    /// Same source scope — the same spans, described the same way. Two staged
    /// changes sharing a scope are two intents for one slot, not two changes.
    package func sameScope(as other: StagedChange) -> Bool {
        fromKey == other.fromKey && fromValue == other.fromValue
            && spanIDs == other.spanIDs
    }

    /// `row` with this change applied, or unchanged when it doesn't match.
    /// The one rewrite rule for everything that stores marks as key/value
    /// rows outside the spans themselves — label sets and quick labels —
    /// so a rename can't update one and strand the other (#177).
    package func applied(to row: TagRow, toKey: String) -> TagRow {
        var row = row
        if normalizeKey(row.key) == fromKey,
           fromValue == nil || row.value == fromValue {
            row.key = toKey
            if let toValue { row.value = toValue }
        }
        return row
    }
}

extension Sequence<StagedChange> {
    /// The spelling `key` will have once this batch's key renames have
    /// applied, in order. Following sequentially matches apply order exactly,
    /// including chains (a→b staged, then b→c: a ends at c) and re-renames.
    package func effectiveKey(_ key: String) -> String {
        var key = key
        for change in self where change.isKeyRename && change.fromKey == key {
            key = normalizeKey(change.toKey)
        }
        return key
    }
}

extension [StagedChange] {
    /// Stage `change` into the batch: anything pending with the same source
    /// scope is replaced rather than duplicated — re-dragging a value (or
    /// re-staging a rename from the pencil) updates the earlier entry, so a
    /// change can't be queued twice (#69). A key rename back onto its own
    /// spelling stages nothing.
    package func adding(_ change: StagedChange) -> [StagedChange] {
        if change.isKeyRename, normalizeKey(change.toKey) == change.fromKey {
            return self
        }
        return filter { !$0.sameScope(as: change) } + [change]
    }
}

/// State and behaviour for the Tag Review tab: scans timespans to compute
/// per-key value cardinality, and stages tag rewrites (renames, moves between
/// keys) that apply as one approved batch. Sibling of `HistoryModel`, owned by
/// `AppModel`.
@MainActor
@Observable
package final class TagReviewModel {
    @ObservationIgnored package unowned let app: AppModel

    package var range: TrailingRange = .days90
    /// Everything the last scan fetched (finished + running), deduplicated.
    package private(set) var spans: [TimeSpan] = []
    package private(set) var hasScanned = false
    package var isScanning = false
    /// Spans fetched so far, for progress while paging a large window.
    package var scannedCount = 0
    package var errorMessage: String?

    /// Pending rewrites, in staging order — applied together on approve.
    package var staged: [StagedChange] = []

    // Batch/rewrite progress, observed by the Approve Changes pane.
    package var isApplying = false
    /// Index into the batch of the change currently applying.
    package var applyIndex = 0
    package var renameDone = 0
    package var renameTotal = 0
    package var renameFailures = 0
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var cancelBatch = false
    /// Invalidates in-flight scans when the range changes mid-fetch.
    @ObservationIgnored private var scanGeneration = 0
    /// The `AppModel.spanDataVersion` the current `spans` snapshot reflects
    /// (#225). Captured when a scan starts, so a mutation landing mid-scan
    /// still reads as stale afterwards. -1 = never scanned.
    @ObservationIgnored private var scannedVersion = -1

    package init(app: AppModel) {
        self.app = app
    }

    /// Forget the scan and anything staged — called when the active backend
    /// switches, since scanned spans and staged rewrites reference ids that
    /// mean nothing in the other store.
    package func reset() {
        scanGeneration += 1     // invalidates any in-flight scan
        scannedVersion = -1
        spans = []
        hasScanned = false
        isScanning = false
        scannedCount = 0
        staged = []
        errorMessage = nil
    }

    // MARK: Scanning

    package func scan() async {
        guard let backend = app.api, app.isReady else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scannedVersion = app.spanDataVersion
        isScanning = true
        scannedCount = 0
        defer { if generation == scanGeneration { isScanning = false } }
        do {
            let from = range.start
            let to = Date().addingTimeInterval(86_400)
            var finished: [TimeSpan] = []
            var token: PageToken?
            // Page until done (cap defensively: 500 pages × 100 = 50k spans).
            for _ in 0..<500 {
                let page = try await backend.timeSpans(from: from, to: to, page: token)
                guard generation == scanGeneration else { return }
                finished += page.timeSpans
                scannedCount = finished.count
                guard let next = page.nextPage, !page.timeSpans.isEmpty else { break }
                token = next
            }
            // The paged query excludes running spans; their tags count too.
            let running = try await backend.timers()
            guard generation == scanGeneration else { return }

            var seen = Set<Int>()
            spans = (running + finished).filter { seen.insert($0.id).inserted }
            scannedCount = spans.count
            hasScanned = true
            errorMessage = nil
        } catch {
            guard generation == scanGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Rescan when span data changed under the last scan (#225) — the
    /// store-observation replacement for the manual Rescan habit. The view
    /// calls it on appearance and whenever `spanDataVersion` bumps while
    /// visible; a fresh snapshot is a no-op. Never during an apply: the
    /// rewrite maintains `spans` itself and marks the snapshot current.
    package func rescanIfStale() async {
        guard hasScanned, !isApplying,
              scannedVersion != app.spanDataVersion else { return }
        await scan()
    }

    // MARK: Stats

    /// Per-key value cardinality over the scanned spans, messiest keys first
    /// (most distinct values), ties alphabetical.
    package var keyStats: [KeyStat] {
        var byKey: [String: [String: (count: Int, seconds: TimeInterval)]] = [:]
        for span in spans {
            let duration = max(0, (span.end ?? Date()).timeIntervalSince(span.start))
            for tag in span.labels {
                let current = byKey[tag.key]?[tag.value] ?? (0, 0)
                byKey[tag.key, default: [:]][tag.value] =
                    (current.count + 1, current.seconds + duration)
            }
        }
        return byKey.map { key, values in
            KeyStat(key: key,
                    values: values
                        .map { ValueStat(value: $0.key, count: $0.value.count, seconds: $0.value.seconds) }
                        .sorted { ($0.count, $1.value) > ($1.count, $0.value) })
        }
        .sorted { ($0.values.count, $1.key) > ($1.values.count, $0.key) }
    }

    /// Scanned spans carrying `key` (and, when given, exactly `value`) — the
    /// blast radius shown before a rename and the set it rewrites.
    package func matches(key: String, value: String? = nil) -> [TimeSpan] {
        spans.filter { span in
            span.labels.contains { $0.key == key && (value == nil || $0.value == value) }
        }
    }

    // MARK: Staging

    package func stage(_ change: StagedChange) {
        staged = staged.adding(change)
    }

    /// The key a staged change will actually land on: key renames staged
    /// before it fold in, since they'll have respelled the key by the time
    /// this change applies. Keeps the Approve pane honest — dropping a value
    /// onto a row whose key has a pending rename reads "to <new name>", and
    /// discarding the rename reverts the description (#69).
    package func effectiveTargetKey(of change: StagedChange) -> String {
        let index = staged.firstIndex { $0.id == change.id } ?? staged.endIndex
        return staged[..<index].effectiveKey(normalizeKey(change.toKey))
    }

    package func discard(_ id: StagedChange.ID) {
        staged.removeAll { $0.id == id }
    }

    /// The matches a staged change may touch: running spans are excluded —
    /// rewriting a timespan that's still ticking proved flaky (its identity
    /// shifts under the list mid-drag), and the popover already edits the
    /// live timer. It becomes movable once stopped and rescanned.
    package func movableMatches(key: String, value: String? = nil) -> [TimeSpan] {
        matches(key: key, value: value).filter { !$0.isRunning }
    }

    /// The spans a staged change would rewrite right now — its blast radius.
    /// Explicit span ids are re-filtered against the tag match, so instances
    /// already moved (or edited away) drop out rather than being re-written.
    package func spans(for change: StagedChange) -> [TimeSpan] {
        let all = movableMatches(key: change.fromKey, value: change.fromValue)
        guard let ids = change.spanIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    /// Apply the staged batch in order. Changes that fail (or are interrupted
    /// by cancel) stay staged — applying again converges, since spans already
    /// rewritten no longer match.
    package func applyStaged() async {
        guard !isApplying, !staged.isEmpty else { return }
        isApplying = true
        cancelBatch = false
        defer { isApplying = false }
        let batch = staged
        var keep: [StagedChange] = []
        // Key renames that have applied so far: later changes in the batch
        // fold them into their keys, because the spans they name have already
        // been respelled on the server. A rename that *failed* is deliberately
        // not folded — its spans still carry the old key.
        var appliedRenames: [StagedChange] = []
        func folded(_ change: StagedChange) -> StagedChange {
            var change = change
            change.fromKey = appliedRenames.effectiveKey(change.fromKey)
            change.toKey = appliedRenames.effectiveKey(change.toKey)
            return change
        }
        for (index, change) in batch.enumerated() {
            applyIndex = index
            if cancelBatch {
                // Fold what's already applied into the remainder, so a later
                // retry still finds its spans under their new spelling.
                keep.append(contentsOf: batch[index...].map(folded))
                break
            }
            let effective = folded(change)
            if await apply(effective) {
                if effective.isKeyRename { appliedRenames.append(effective) }
            } else {
                keep.append(effective)
            }
        }
        staged = keep
    }

    /// Stop the batch: the in-flight rewrite halts and everything not fully
    /// applied stays staged.
    package func cancelApply() {
        cancelBatch = true
        cancelRequested = true
    }

    /// Apply one change; false when it should stay staged (failures/cancel).
    private func apply(_ change: StagedChange) async -> Bool {
        let toKey = normalizeKey(change.toKey)
        guard !toKey.isEmpty else { return false }
        // The server rejects unknown keys: make sure the target definition
        // exists, carrying the source key's color. The old definition stays
        // on the server (traggo keeps it; harmless and still reusable).
        if !app.tagDefinitions.contains(where: { $0.key == toKey }) {
            let color = app.tagDefinitions.first(where: { $0.key == change.fromKey })?.color
                ?? "#2196f3"
            do {
                try await app.api?.createLabelDefinition(key: toKey, color: color)
                await app.refresh()
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        await rewrite(spans(for: change)) { tags in
            tags.map { tag in
                tag.key == change.fromKey
                    && (change.fromValue == nil || tag.value == change.fromValue)
                    ? SpanLabel(key: toKey, value: change.toValue ?? tag.value)
                    : tag
            }
        }
        // Whole-value (and whole-key) changes update local tag sets, quick
        // labels, and per-value color overrides too, or quick-starting a
        // set (or clicking a quick chip) would recreate the old spelling and
        // the renamed value would lose its color (#177). Subset moves leave
        // all three alone — the value (and its color) still legitimately
        // means the rest.
        if change.spanIDs == nil {
            updateTagSets(for: change, toKey: toKey)
            app.migrateValueColors(fromKey: change.fromKey, fromValue: change.fromValue,
                                   toKey: toKey, toValue: change.toValue)
        }
        return renameFailures == 0 && !cancelRequested
    }

    private func updateTagSets(for change: StagedChange, toKey: String) {
        app.tagSets = app.tagSets.map { set in
            var set = set
            set.tags = set.tags.map { change.applied(to: $0, toKey: toKey) }
            return set
        }
        app.quickLabels = app.quickLabels.mapValues { rows in
            rows.map { change.applied(to: $0, toKey: toKey) }
        }
    }

    /// The rewrite engine: N × updateTimeSpan, one span at a time — traggo has
    /// no bulk rename. Not transactional; failures are counted and skipped.
    private func rewrite(_ matches: [TimeSpan],
                         _ transform: ([SpanLabel]) -> [SpanLabel]) async {
        renameDone = 0
        renameTotal = matches.count
        renameFailures = 0
        cancelRequested = false
        guard let backend = app.api, !matches.isEmpty else { return }
        for span in matches {
            if cancelRequested { break }
            do {
                // A nil end leaves running spans running.
                let updated = try await backend.updateTimeSpan(
                    id: span.id, start: span.start, end: span.end,
                    labels: transform(span.labels), note: span.note)
                if let index = spans.firstIndex(where: { $0.id == updated.id }) {
                    spans[index] = updated
                }
            } catch {
                renameFailures += 1
                errorMessage = error.localizedDescription
            }
            renameDone += 1
        }
        // The rewrite may have touched the running timer or loaded history.
        await app.refresh()
        await app.history.reloadIfLoaded()
        // Publish the mutation like every other write path — but this
        // snapshot already reflects it (spans were patched in the loop), so
        // mark it current rather than triggering a rescan of our own work.
        app.noteSpanDataChanged()
        scannedVersion = app.spanDataVersion
        app.syncSoon()
    }
}
