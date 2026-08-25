import Foundation
import MomentTallyCore
import Observation

/// What a sync run is doing, for the Settings surface.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
}

/// Reconciles the local store with a Moment Tally server (#33). Local-first:
/// every write lands in SQLite immediately and this engine runs after the
/// fact — pull the label-definition / label-set / preference snapshots and
/// the timespan delta feed, merge with last-writer-wins per record, then
/// push whatever stayed dirty. Offline edits queue naturally (dirty flags
/// and tombstones persist); a failed run changes nothing about what is
/// owed and the next run picks it all up.
///
/// `@MainActor` because its observable status drives Settings and its
/// callbacks touch AppModel; the actual work awaits on the database queue
/// and URLSession, so nothing heavy runs on the main thread.
@MainActor
@Observable
final class SyncEngine {
    let store: LocalBackend
    let server: any SyncServerAPI

    var status: SyncStatus = .idle
    var lastSyncedAt: Date?

    /// Bridges to the two preference values, which live in UserDefaults via
    /// AppModel rather than in the store. `applyPreferences` must not
    /// re-mark the preferences dirty (AppModel suppresses its observers).
    var readPreferences: () -> (colorByValue: Bool, menuLabelSetLimit: Int) = { (true, 5) }
    var applyPreferences: (_ colorByValue: Bool, _ menuLabelSetLimit: Int) -> Void = { _, _ in }
    /// Called after a run that changed local data, so the UI reloads.
    var onLocalChange: () -> Void = {}

    /// Defensive bound on the pull loop, same idea as the importer's.
    var maxPullPages = 10_000
    /// The color given to definitions the engine has to invent because a
    /// pushed span or value color references an undefined key.
    static let defaultKeyColor = "#2196f3"

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false

    init(store: LocalBackend, server: any SyncServerAPI) {
        self.store = store
        self.server = server
        lastSyncedAt = (try? store.syncServer())?.lastSyncedAt
    }

    // MARK: Triggers

    /// The steady background cadence — mainly for *pulling* what other
    /// devices pushed; local writes trigger their own runs via `kick`.
    func startPeriodicSync(every seconds: Double = 60) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    /// Cancel all scheduled work (disconnect).
    func stop() {
        periodicTask?.cancel()
        kickTask?.cancel()
    }

    /// Debounced trigger for "something changed locally": batches a burst of
    /// edits into one run shortly after they settle.
    func kick(after seconds: Double = 3) {
        kickTask?.cancel()
        kickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    /// Run a sync immediately; if one is in flight, run another after it
    /// (the in-flight run may already have pushed past its snapshot).
    func syncNow() async {
        if syncTask != nil {
            rerunRequested = true
            return
        }
        let task = Task { await runOnce() }
        syncTask = task
        await task.value
        syncTask = nil
        if rerunRequested {
            rerunRequested = false
            await syncNow()
        }
    }

    private func runOnce() async {
        status = .syncing
        do {
            let changed = try await performSync()
            let finished = Date()
            try await store.recordSyncCompleted(at: finished)
            lastSyncedAt = finished
            status = .idle
            if changed { onLocalChange() }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: The reconciliation pass

    /// One full pass; returns whether local data changed. Order matters:
    /// definitions before value colors and spans (the server rejects labels
    /// with undefined keys), pulls before pushes (conflicts resolve against
    /// fresh server state, and the losers of last-writer-wins never push).
    func performSync() async throws -> Bool {
        var changed = false

        // 1. Label definitions: snapshot merge, then push local winners.
        let remoteDefinitions = try await server.labelDefinitions()
        let (definitionPushes, definitionsChanged) =
            try await store.mergeRemoteLabelDefinitions(remoteDefinitions)
        changed = changed || definitionsChanged
        for push in definitionPushes {
            if push.existsOnServer {
                try await server.updateLabelDefinition(key: push.key, color: push.color)
            } else {
                do {
                    try await server.createLabelDefinition(key: push.key, color: push.color)
                } catch is ServerRejection {
                    // Raced with another device creating the key: update.
                    try await server.updateLabelDefinition(key: push.key, color: push.color)
                }
            }
            try await store.recordLabelDefinitionPushed(key: push.key,
                                                        modifiedAt: push.modifiedAt)
        }

        // 2. Value colors: push queued clears, then merge and push winners.
        for tombstone in try await store.valueColorTombstones() {
            do {
                try await server.clearLabelValueColor(key: tombstone.key,
                                                      value: tombstone.value)
            } catch is ServerRejection {
                // The key (or override) is already gone there — same result.
            }
            try await store.removeValueColorTombstone(key: tombstone.key,
                                                      value: tombstone.value)
        }
        let (colorPushes, colorsChanged) =
            try await store.mergeRemoteValueColors(remoteDefinitions)
        changed = changed || colorsChanged
        try await ensureDefinitions(for: Set(colorPushes.map(\.key)))
        for push in colorPushes {
            try await server.setLabelValueColor(key: push.key, value: push.value,
                                                color: push.color)
            try await store.recordValueColorPushed(key: push.key, value: push.value,
                                                   modifiedAt: push.modifiedAt)
        }

        // 3. Label sets: push queued deletions, then merge and push winners.
        for tombstone in try await store.labelSetTombstones() {
            do {
                try await server.removeLabelSet(id: tombstone.serverId)
            } catch is ServerRejection {}
            try await store.removeLabelSetTombstone(serverId: tombstone.serverId)
        }
        let remoteSets = try await server.labelSets()
        let (setPushes, setsChanged) = try await store.mergeRemoteLabelSets(remoteSets)
        changed = changed || setsChanged
        for push in setPushes {
            if let serverId = push.serverId {
                do {
                    try await server.updateLabelSet(id: serverId, name: push.name,
                                                    symbolName: push.symbolName,
                                                    labels: push.labels,
                                                    quickLabels: push.quickLabels,
                                                    position: push.position)
                    try await store.recordLabelSetPushed(localId: push.localId,
                                                         serverId: serverId,
                                                         modifiedAt: push.modifiedAt)
                } catch is ServerRejection {
                    // Deleted there since the snapshot: the local edit still
                    // wins — re-create under a fresh id.
                    let newId = try await server.createLabelSet(
                        name: push.name, symbolName: push.symbolName,
                        labels: push.labels, quickLabels: push.quickLabels,
                        position: push.position)
                    try await store.recordLabelSetPushed(localId: push.localId,
                                                         serverId: newId,
                                                         modifiedAt: push.modifiedAt)
                }
            } else {
                let newId = try await server.createLabelSet(
                    name: push.name, symbolName: push.symbolName,
                    labels: push.labels, quickLabels: push.quickLabels,
                    position: push.position)
                try await store.recordLabelSetPushed(localId: push.localId,
                                                     serverId: newId,
                                                     modifiedAt: push.modifiedAt)
            }
        }

        // 4. Preferences: one record, same rule.
        if let state = try store.syncServer() {
            let remotePreferences = try await server.userPreferences()
            let local = readPreferences()
            if state.prefsDirty,
               (state.prefsModifiedAt ?? .distantPast) > remotePreferences.updatedAt {
                try await server.setUserPreferences(colorByValue: local.colorByValue,
                                                    menuLabelSetLimit: local.menuLabelSetLimit)
                try await store.clearPreferencesDirty(ifModifiedAt: state.prefsModifiedAt)
            } else {
                if local.colorByValue != remotePreferences.colorByValue
                    || local.menuLabelSetLimit != remotePreferences.menuLabelSetLimit {
                    applyPreferences(remotePreferences.colorByValue,
                                     remotePreferences.menuLabelSetLimit)
                    changed = true
                }
                try await store.clearPreferencesDirty(ifModifiedAt: state.prefsModifiedAt)
            }
        }

        // 5. Timespans — pull the delta feed, advancing the checkpoint per
        // page so an interrupted walk resumes where it stopped. Deletions
        // are collected across pages (the server re-delivers them per page)
        // and applied once at the end.
        var checkpoint = (try store.syncServer())?.checkpoint
            ?? Date(timeIntervalSince1970: 0)
        var afterId = (try store.syncServer())?.checkpointAfterId ?? 0
        var deletions: [Int: RemoteDeletion] = [:]
        for _ in 0..<maxPullPages {
            let page = try await server.timeSpanChanges(since: checkpoint, afterId: afterId)
            for span in page.timeSpans {
                switch try await store.applyRemoteSpan(span) {
                case .inserted, .updated, .resurrected:
                    changed = true
                case .localWins, .tombstoneWins, .deletedLocally, .noop:
                    break
                }
            }
            for deletion in page.deleted
                where deletions[deletion.id].map({ $0.deletedAt < deletion.deletedAt }) ?? true {
                deletions[deletion.id] = deletion
            }
            if let last = page.timeSpans.last {
                checkpoint = last.updatedAt
                afterId = last.id
                try await store.advanceCheckpoint(checkpoint, afterId: afterId)
            }
            if !page.hasMore { break }
        }
        for deletion in deletions.values {
            if try await store.applyRemoteSpanDeletion(deletion) == .deletedLocally {
                changed = true
            }
        }

        // 6. Timespans — push deletions, then dirty rows.
        for tombstone in try await store.spanTombstones() {
            do {
                try await server.removeTimeSpan(id: tombstone.serverId)
            } catch is ServerRejection {}
            try await store.removeSpanTombstone(serverId: tombstone.serverId)
        }
        let spanPushes = try await store.pendingSpanPushes()
        try await ensureDefinitions(for: Set(spanPushes.flatMap { $0.labels.map(\.key) }))
        for push in spanPushes {
            if let serverId = push.serverId {
                do {
                    try await server.updateTimeSpan(id: serverId, start: push.start,
                                                    end: push.end, labels: push.labels,
                                                    note: push.note)
                    try await store.recordSpanPushed(localId: push.localId,
                                                     serverId: serverId,
                                                     modifiedAt: push.modifiedAt)
                } catch is ServerRejection {
                    // Deleted there since the pull: the local edit wins.
                    let newId = try await server.createTimeSpan(
                        start: push.start, end: push.end,
                        labels: push.labels, note: push.note)
                    try await store.recordSpanPushed(localId: push.localId,
                                                     serverId: newId,
                                                     modifiedAt: push.modifiedAt)
                }
            } else {
                let newId = try await server.createTimeSpan(
                    start: push.start, end: push.end,
                    labels: push.labels, note: push.note)
                try await store.recordSpanPushed(localId: push.localId,
                                                 serverId: newId,
                                                 modifiedAt: push.modifiedAt)
            }
        }

        return changed
    }

    /// The server rejects labels whose key has no definition, so create any
    /// missing ones (local store and server both) before pushing records
    /// that reference them.
    private func ensureDefinitions(for keys: Set<String>) async throws {
        let known = try await store.definitionKeys()
        for key in keys.subtracting(known).sorted() {
            do {
                try await server.createLabelDefinition(key: key,
                                                       color: Self.defaultKeyColor)
            } catch is ServerRejection {
                // Exists there already (raced or predates us) — fine.
            }
            try await store.insertCleanDefinition(key: key, color: Self.defaultKeyColor)
        }
    }
}
