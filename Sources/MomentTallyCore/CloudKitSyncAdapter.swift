// Apple-only (#85): CloudKit does not exist on Linux; without it this file
// contributes nothing to the core build.
#if canImport(CloudKit)
import CloudKit
import Foundation

// MARK: - The real-CKSyncEngine adapter (#121)
//
// The one piece of the CloudKit transport CI can compile but never execute:
// a mechanical translation between the system CKSyncEngine and the
// CloudKitSurface protocols the transport is written against. No sync
// logic lives here — every decision the flow makes (LWW, conflict
// resolution, queue derivation) happens in CloudKitTransport, which is
// fully exercised against the fake CK layer. Keep it that way: code in
// this file is code no test can reach.
//
// The engine runs with automatic sync off. The transport's whole design is
// a *driven* flow — fetch, derive work, send, all inside one syncNow —
// with the SyncEngine-style trigger machinery (periodic, debounced kick)
// deciding when runs happen. Letting CKSyncEngine schedule its own syncs
// would deliver events outside any run. The cost is no push-driven sync in
// v1; the periodic cadence covers it, exactly as it does for the
// self-hosted transport.

package final class CloudKitSyncAdapter: NSObject, CloudSyncEngineControl, CKSyncEngineDelegate,
                                         @unchecked Sendable {
    // @unchecked Sendable: CKSyncEngineDelegate requires Sendable. With
    // automatic sync off, the engine only calls back inside our own
    // fetchChanges/sendChanges awaits, so the mutable state (`delegate`,
    // set once at wiring) is never actually raced.

    /// The transport. Weak by the same ownership rule as the fake engine:
    /// whoever wires the pair owns both.
    package weak var delegate: (any CloudSyncEngineDelegate)?

    /// Batches are capped well under the server's ~400-record operation
    /// limit; the engine keeps calling back until the queue drains.
    package var batchLimit = 200

    private var engine: CKSyncEngine!

    /// - Parameter state: the persisted `sync_server.ck_state`, decoded
    ///   back into the engine; nil starts from scratch (full re-fetch).
    package init(containerId: String = CloudKitSchema.containerId, state: Data?) {
        super.init()
        let serialization = state.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: containerId).privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self)
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
    }

    // MARK: CloudSyncEngineControl (transport → engine)

    package var pendingChanges: [CloudPendingChange] {
        engine.state.pendingRecordZoneChanges.compactMap(Self.pendingChange)
    }

    package func add(pendingChanges changes: [CloudPendingChange]) {
        engine.state.add(pendingRecordZoneChanges: changes.map(Self.ckPendingChange))
    }

    package func remove(pendingChanges changes: [CloudPendingChange]) {
        engine.state.remove(pendingRecordZoneChanges: changes.map(Self.ckPendingChange))
    }

    package func addPendingZoneSave() {
        engine.state.add(pendingDatabaseChanges:
            [.saveZone(CKRecordZone(zoneID: CloudKitSchema.zoneID))])
    }

    package func fetchChanges() async throws {
        try await engine.fetchChanges()
    }

    package func sendChanges() async throws {
        try await engine.sendChanges()
    }

    // MARK: CKSyncEngineDelegate (engine → transport)

    package func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                await delegate?.handleEvent(.stateUpdate(data))
            }

        case .accountChange(let change):
            let mapped: CloudAccountChange
            switch change.changeType {
            case .signIn: mapped = .signIn
            case .signOut: mapped = .signOut
            case .switchAccounts: mapped = .switchAccounts
            @unknown default: return
            }
            await delegate?.handleEvent(.accountChange(mapped))

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == CloudKitSchema.zoneID {
                let reason: CloudZoneDeletionReason
                switch deletion.reason {
                case .deleted: reason = .deleted
                case .purged: reason = .purged
                case .encryptedDataReset: reason = .encryptedDataReset
                @unknown default: reason = .deleted
                }
                await delegate?.handleEvent(.zoneDeleted(reason: reason))
            }

        case .fetchedRecordZoneChanges(let changes):
            await delegate?.handleEvent(.fetchedRecordZoneChanges(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map {
                    CloudRecordDeletion(recordID: $0.recordID, recordType: $0.recordType)
                }))

        case .sentRecordZoneChanges(let sent):
            var failedSaves: [CloudFailedSave] = []
            for failure in sent.failedRecordSaves {
                if let mapped = Self.saveFailure(failure.error) {
                    failedSaves.append(CloudFailedSave(record: failure.record, failure: mapped))
                } else {
                    // Retryable (network, throttling, quota): per the
                    // surface contract these never reach the transport as
                    // per-record failures — re-queue blindly and let the
                    // next run retry. No policy here; the transport would
                    // do nothing smarter.
                    syncEngine.state.add(pendingRecordZoneChanges:
                        [.saveRecord(failure.record.recordID)])
                }
            }
            await delegate?.handleEvent(.sentRecordZoneChanges(
                saved: sent.savedRecords,
                failedSaves: failedSaves,
                deleted: sent.deletedRecordIDs,
                failedDeletes: Array(sent.failedRecordDeletes.keys)))

        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    package func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                           syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch? {
        let scoped = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
        let slice = Array(scoped.prefix(batchLimit))
        guard !slice.isEmpty, let delegate else { return nil }
        guard let batch = await delegate.nextRecordZoneChangeBatch(
            pending: slice.compactMap(Self.pendingChange)) else {
            return nil
        }
        // The surface contract: everything passed to the delegate is
        // consumed, batched or declined; the transport re-queues explicitly
        // when it wants a retry. The direct batch initializer (unlike the
        // record-provider one) doesn't touch engine state, so consume here.
        syncEngine.state.remove(pendingRecordZoneChanges: slice)
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave,
                                                  recordIDsToDelete: batch.recordIDsToDelete,
                                                  atomicByZone: false)
    }

    // MARK: Mapping

    private static func pendingChange(_ change: CKSyncEngine.PendingRecordZoneChange)
        -> CloudPendingChange? {
        switch change {
        case .saveRecord(let id): return .saveRecord(id)
        case .deleteRecord(let id): return .deleteRecord(id)
        @unknown default: return nil
        }
    }

    private static func ckPendingChange(_ change: CloudPendingChange)
        -> CKSyncEngine.PendingRecordZoneChange {
        switch change {
        case .saveRecord(let id): return .saveRecord(id)
        case .deleteRecord(let id): return .deleteRecord(id)
        }
    }

    /// The three per-record failures the delegate flow branches on; nil
    /// means retryable, handled by re-queueing above.
    private static func saveFailure(_ error: CKError) -> CloudSaveFailure? {
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else { return nil }
            return .conflict(serverRecord: serverRecord)
        case .zoneNotFound, .userDeletedZone:
            return .zoneNotFound
        case .unknownItem:
            return .unknownItem
        default:
            return nil
        }
    }
}
#endif
