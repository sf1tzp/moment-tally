// Apple-only (#85): CloudKit does not exist on Linux; without it this file
// contributes nothing to the core build.
#if canImport(CloudKit)
import CloudKit
import Foundation

// MARK: - The CloudKit transport (#121)
//
// The CKSyncEngine delegate flow against the SyncStore merge primitives —
// the CloudKit sibling of the app target's SyncEngine, with the control
// flow inverted to match the transport: instead of pull-snapshots-then-push,
// the engine calls back for batches and delivers per-record outcomes as
// events. Written entirely against the CloudKitSurface protocols, so the
// same code runs in production (behind the thin CKSyncEngine adapter) and
// in CI (behind the fake CK layer).
//
// The work owed is derived from the store each run — dirty flags and
// tombstones — never trusted to engine state: a failed run changes nothing
// about what is owed, and the next run picks it all up. The engine's own
// pending queue is transient machinery in between.

@MainActor
package final class CloudKitTransport: CloudSyncEngineDelegate {
    package let store: LocalBackend
    /// Set after init — the engine needs its delegate first, and this class
    /// is the delegate.
    package weak var engine: (any CloudSyncEngineControl)?

    /// The two preference values live in UserDefaults via AppModel, not in
    /// the store — bridged by closures exactly like SyncEngine's.
    /// `applyPreferences` must not re-mark the preferences dirty.
    package var readPreferences: () -> (colorByValue: Bool, menuLabelSetLimit: Int) = { (true, 5) }
    package var applyPreferences: (_ colorByValue: Bool, _ menuLabelSetLimit: Int) -> Void = { _, _ in }
    /// Non-fatal trouble the flow works around but a human should hear
    /// about: undecodable records (newer build), unexpected types, store
    /// errors during event handling.
    package var onProblem: (String) -> Void = { _ in }

    /// The color given to definitions the transport has to invent because a
    /// dirty span or value color references an undefined key.
    package static let defaultKeyColor = "#2196f3"

    /// What was encoded into the in-flight batch, keyed by record name, so
    /// per-record send outcomes can settle the right row — and clear dirty
    /// only if the row wasn't edited again mid-send.
    private struct InFlight {
        let identity: CloudRecordIdentity
        let rowModifiedAt: Date?
    }
    private var inFlight: [String: InFlight] = [:]

    /// Saves that must wait for the next run (zoneNotFound: the zone save
    /// itself has to go first, and re-queueing inside the same send would
    /// spin on the same failure).
    private var deferredChanges: [CloudPendingChange] = []
    private var zoneSaveNeeded = false

    /// Whether the current run changed local data, for the caller's
    /// UI-reload decision.
    private(set) var localChanged = false

    package init(store: LocalBackend) {
        self.store = store
    }

    // MARK: One run

    /// One full pass; returns whether local data changed. Pulls first for
    /// the same reason performSync does: conflicts resolve against fresh
    /// server state, and the losers of last-writer-wins never push.
    @discardableResult
    package func syncNow() async throws -> Bool {
        guard let engine else { return false }
        localChanged = false
        try await engine.fetchChanges()
        try await enqueueLocalWork(engine)
        try await engine.sendChanges()
        try await store.recordSyncCompleted(at: Date())
        return localChanged
    }

    private func enqueueLocalWork(_ engine: any CloudSyncEngineControl) async throws {
        if !deferredChanges.isEmpty {
            engine.add(pendingChanges: deferredChanges)
            deferredChanges = []
        }
        // The zone save is queued until one run has completed end to end
        // (lastSyncedAt), and again whenever the zone goes missing — saving
        // an existing zone is a no-op, so erring toward queueing is safe.
        let neverCompletedARun = try store.syncServer()?.lastSyncedAt == nil
        if zoneSaveNeeded || neverCompletedARun {
            engine.addPendingZoneSave()
            zoneSaveNeeded = false
        }
        try await store.ensureCloudDefinitions(defaultColor: Self.defaultKeyColor)
        let work = try await store.cloudPushWork()
        engine.add(pendingChanges:
            work.deletes.map { .deleteRecord(Self.recordID($0)) }
                + work.saves.map { .saveRecord(Self.recordID($0)) })
    }

    // MARK: CloudSyncEngineDelegate

    package func handleEvent(_ event: CloudSyncEvent) async {
        // The surface can't throw out of an event; a store failure here
        // leaves dirty flags and tombstones exactly as they were, so the
        // next run re-derives the same work. Surface it and move on.
        do {
            try await handle(event)
        } catch {
            onProblem("sync event failed: \(error)")
        }
    }

    private func handle(_ event: CloudSyncEvent) async throws {
        switch event {
        case .stateUpdate(let data):
            try await store.saveCloudKitState(data)

        case .accountChange(let change):
            switch change {
            case .signIn:
                break   // connecting is a user decision, made in Settings
            case .signOut:
                try store.disconnectSyncServer()
            case .switchAccounts:
                // Another account's zone is foreign ground: drop every
                // record-level assumption and stop syncing until the user
                // reconnects under the new account.
                try await store.resetCloudKitBookkeeping()
                try store.disconnectSyncServer()
            }

        case .fetchedRecordZoneChanges(let modifications, let deletions):
            for record in modifications {
                _ = try await merge(record)
            }
            for deletion in deletions {
                try await merge(deletion)
            }

        case .zoneDeleted:
            try await store.resetCloudKitBookkeeping()
            zoneSaveNeeded = true

        case .sentRecordZoneChanges(let saved, let failedSaves, let deleted, let failedDeletes):
            for record in saved {
                try await handleSaved(record)
            }
            for failure in failedSaves {
                try await handleFailedSave(failure)
            }
            // Failed deletes are moot by definition — the record is already
            // gone — so both lists settle the same bookkeeping.
            for recordID in deleted + failedDeletes {
                try await store.settleCloudDeletion(recordName: recordID.recordName)
            }
        }
    }

    package func nextRecordZoneChangeBatch(pending: [CloudPendingChange]) async -> CloudRecordBatch? {
        var batch = CloudRecordBatch()
        for change in pending {
            switch change {
            case .deleteRecord(let recordID):
                batch.recordIDsToDelete.append(recordID)
            case .saveRecord(let recordID):
                do {
                    // nil (row gone, or clean again) leaves the change
                    // consumed — the record-provider contract.
                    if let record = try await materialize(recordID) {
                        batch.recordsToSave.append(record)
                    }
                } catch {
                    onProblem("encoding \(recordID.recordName) failed: \(error)")
                }
            }
        }
        return batch
    }

    // MARK: Materializing saves

    private func materialize(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        let name = recordID.recordName
        guard let identity = try await store.cloudIdentity(forRecordName: name) else {
            return nil
        }
        // Base every save on the last server copy we hold — its change tag
        // is what makes this an update rather than a conflict. No cached
        // copy means a fresh instance: right for first upload, and the
        // self-healing path after a lost cache (one conflict, then heal).
        let base = try await store.cloudRecordArchive(recordName: name)
            .flatMap(Self.unarchiveRecord)

        switch identity {
        case .span(let uuid):
            guard let (span, rowModifiedAt) = try await store.cloudSpanSave(uuid: uuid) else {
                return nil
            }
            return stage(name: name, identity: identity, rowModifiedAt: rowModifiedAt,
                         record: base ?? CloudKitRecordCodec.record(for: span)) {
                CloudKitRecordCodec.apply(span, to: $0)
            }

        case .labelSet(let id):
            guard let (set, rowModifiedAt) = try await store.cloudLabelSetSave(id: id) else {
                return nil
            }
            return stage(name: name, identity: identity, rowModifiedAt: rowModifiedAt,
                         record: base ?? CloudKitRecordCodec.record(for: set)) {
                CloudKitRecordCodec.apply(set, to: $0)
            }

        case .labelDefinition(let key):
            guard let (definition, rowModifiedAt) = try await store.cloudDefinitionSave(key: key) else {
                return nil
            }
            return stage(name: name, identity: identity, rowModifiedAt: rowModifiedAt,
                         record: base ?? CloudKitRecordCodec.record(for: definition, recordName: name)) {
                CloudKitRecordCodec.apply(definition, to: $0)
            }

        case .valueColor(let key, let value):
            guard let (valueColor, rowModifiedAt) = try await store.cloudValueColorSave(
                key: key, value: value) else {
                return nil
            }
            return stage(name: name, identity: identity, rowModifiedAt: rowModifiedAt,
                         record: base ?? CloudKitRecordCodec.record(for: valueColor, recordName: name)) {
                CloudKitRecordCodec.apply(valueColor, to: $0)
            }

        case .preferences:
            guard let state = try store.syncServer(), state.prefsDirty else { return nil }
            let local = readPreferences()
            let preferences = CloudPreferences(colorByValue: local.colorByValue,
                                               menuLabelSetLimit: local.menuLabelSetLimit,
                                               modifiedAt: state.prefsModifiedAt ?? .distantPast)
            return stage(name: name, identity: identity, rowModifiedAt: state.prefsModifiedAt,
                         record: base ?? CloudKitRecordCodec.record(for: preferences)) {
                CloudKitRecordCodec.apply(preferences, to: $0)
            }
        }
    }

    private func stage(name: String, identity: CloudRecordIdentity, rowModifiedAt: Date?,
                       record: CKRecord, apply: (CKRecord) -> Void) -> CKRecord {
        apply(record)
        inFlight[name] = InFlight(identity: identity, rowModifiedAt: rowModifiedAt)
        return record
    }

    // MARK: Send outcomes

    private func handleSaved(_ record: CKRecord) async throws {
        let name = record.recordID.recordName
        // The post-save server copy carries the fresh change tag — the base
        // for every future save of this record.
        try await store.storeCloudRecordArchive(recordName: name, Self.archive(record))
        guard let flight = inFlight.removeValue(forKey: name) else { return }
        switch flight.identity {
        case .span(let uuid):
            try await store.recordCloudSpanPushed(uuid: uuid, modifiedAt: flight.rowModifiedAt)
        case .labelSet(let id):
            try await store.recordCloudLabelSetPushed(id: id, modifiedAt: flight.rowModifiedAt)
        case .labelDefinition(let key):
            try await store.recordLabelDefinitionPushed(key: key, modifiedAt: flight.rowModifiedAt)
        case .valueColor(let key, let value):
            try await store.recordValueColorPushed(key: key, value: value,
                                                   modifiedAt: flight.rowModifiedAt)
        case .preferences:
            try await store.clearPreferencesDirty(ifModifiedAt: flight.rowModifiedAt)
        }
    }

    private func handleFailedSave(_ failure: CloudFailedSave) async throws {
        let recordID = failure.record.recordID
        inFlight.removeValue(forKey: recordID.recordName)
        switch failure.failure {
        case .conflict(let serverRecord):
            // Merge the server copy exactly as if fetched — LWW decides,
            // and the copy (with its current change tag) lands in the
            // cache. If the local edit still wins, re-queue: the retry
            // encodes onto that cached copy and goes through.
            if try await merge(serverRecord) {
                engine?.add(pendingChanges: [.saveRecord(recordID)])
            }
        case .zoneNotFound:
            // The zone save must go out before this record can; within the
            // same send that ordering can't be forced, so park the save for
            // the next run.
            zoneSaveNeeded = true
            deferredChanges.append(.saveRecord(recordID))
        case .unknownItem:
            // Deleted server-side after our cached copy. The local edit
            // wins locally (we were pushing it): drop the stale base so the
            // retry goes out as a fresh create.
            try await store.deleteCloudRecordCache(recordName: recordID.recordName)
            engine?.add(pendingChanges: [.saveRecord(recordID)])
        }
    }

    // MARK: Merging fetched (or conflicting) server copies

    /// Merge one server record into the store; returns whether the local
    /// copy is still dirty afterwards (the local edit won and wants to
    /// push). Shared by the fetch path and the save-conflict path — a
    /// conflict is just a fetch that arrived the hard way.
    private func merge(_ record: CKRecord) async throws -> Bool {
        let name = record.recordID.recordName
        try await store.storeCloudRecordArchive(recordName: name, Self.archive(record))
        do {
            switch record.recordType {
            case CloudKitSchema.RecordType.span:
                let outcome = try await store.applyCloudSpan(
                    try CloudKitRecordCodec.span(from: record))
                noteLocalChange(outcome)
                return outcome == .localWins

            case CloudKitSchema.RecordType.labelSet:
                let outcome = try await store.applyCloudLabelSet(
                    try CloudKitRecordCodec.labelSet(from: record))
                noteLocalChange(outcome)
                return outcome == .localWins

            case CloudKitSchema.RecordType.labelDefinition:
                let result = try await store.applyCloudDefinition(
                    try CloudKitRecordCodec.labelDefinition(from: record), recordName: name)
                noteLocalChange(result.outcome)
                queueDuplicateDeletion(result.duplicateRecordToDelete)
                return result.outcome == .localWins

            case CloudKitSchema.RecordType.valueColor:
                let result = try await store.applyCloudValueColor(
                    try CloudKitRecordCodec.valueColor(from: record), recordName: name)
                noteLocalChange(result.outcome)
                queueDuplicateDeletion(result.duplicateRecordToDelete)
                return result.outcome == .localWins

            case CloudKitSchema.RecordType.preferences:
                return try await mergePreferences(
                    try CloudKitRecordCodec.preferences(from: record))

            default:
                onProblem("unknown record type \(record.recordType)")
                return false
            }
        } catch let error as CloudKitRecordCodec.DecodeError {
            // A newer build's record (or a malformed one) stays undecoded —
            // and unmerged — until this build can read it; the copy in the
            // cache keeps later saves of *other* fields conflict-free.
            onProblem("undecodable \(record.recordType) record: \(error)")
            return false
        }
    }

    private func merge(_ deletion: CloudRecordDeletion) async throws {
        let name = deletion.recordID.recordName
        switch deletion.recordType {
        case CloudKitSchema.RecordType.span:
            noteLocalChange(try await store.applyCloudSpanDeletion(uuid: name))
        case CloudKitSchema.RecordType.labelSet:
            noteLocalChange(try await store.applyCloudLabelSetDeletion(uuid: name))
        case CloudKitSchema.RecordType.labelDefinition:
            noteLocalChange(try await store.applyCloudDefinitionDeletion(recordName: name))
        case CloudKitSchema.RecordType.valueColor:
            noteLocalChange(try await store.applyCloudValueColorDeletion(recordName: name))
        default:
            // Preferences never delete; anything else is a future build's
            // concern.
            break
        }
    }

    private func mergePreferences(_ remote: CloudPreferences) async throws -> Bool {
        guard let state = try store.syncServer() else { return false }
        if state.prefsDirty, (state.prefsModifiedAt ?? .distantPast) > remote.modifiedAt {
            return true   // local edit wins; it pushes
        }
        let local = readPreferences()
        if local.colorByValue != remote.colorByValue
            || local.menuLabelSetLimit != remote.menuLabelSetLimit {
            applyPreferences(remote.colorByValue, remote.menuLabelSetLimit)
            localChanged = true
        }
        try await store.clearPreferencesDirty(ifModifiedAt: state.prefsModifiedAt)
        return false
    }

    private func queueDuplicateDeletion(_ recordName: String?) {
        guard let recordName else { return }
        engine?.add(pendingChanges: [.deleteRecord(Self.recordID(recordName))])
    }

    private func noteLocalChange(_ outcome: RemoteApplyOutcome) {
        switch outcome {
        case .inserted, .updated, .resurrected, .deletedLocally:
            localChanged = true
        case .localWins, .tombstoneWins, .noop:
            break
        }
    }

    // MARK: Record plumbing

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: CloudKitSchema.zoneID)
    }

    private static func archive(_ record: CKRecord) -> Data {
        // Encoding a CKRecord (NSSecureCoding) cannot fail.
        try! NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
    }

    private static func unarchiveRecord(_ data: Data) -> CKRecord? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }
}
#endif
