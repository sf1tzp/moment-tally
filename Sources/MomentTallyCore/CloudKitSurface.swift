import CloudKit
import Foundation

// MARK: - The CloudKit surface the transport drives (#121)
//
// CKSyncEngine inverts control relative to SyncServerAPI: instead of the
// engine calling pull/push methods, the *system* engine calls a delegate —
// "give me the next batch of records to send", "here is what a fetch
// returned" — and owns the pending-change set, the change tokens, and the
// retry/backoff schedule inside an opaque state serialization.
//
// The transport implements that delegate flow, but not against CKSyncEngine
// directly: CKSyncEngine's event types (`CKSyncEngine.Event` and its
// payloads) have no public initializers, so nothing that consumes them can
// ever run under test — and there is no local CloudKit. So the surface here
// is a pair of protocols over plain value types that *mirror* the
// CKSyncEngine flow. `CKRecord` itself stays: it is a plain object until an
// operation ships it (the codec already leans on this), and the opaque
// server change tag it carries is exactly what conflict semantics hinge on.
//
// Production wires a thin adapter translating real CKSyncEngine callbacks
// into these values — mechanical, no logic, the only code CI can't reach.
// Tests wire the fake CK layer, which plays both the engine and the server
// (the FakeSyncServer pattern, repeated).

// MARK: Pending work (the engine's queue)

/// One unit of record-zone work the engine owes the server — the value
/// mirror of `CKSyncEngine.PendingRecordZoneChange`. The engine persists
/// these inside its state serialization, so the queue survives relaunch.
package enum CloudPendingChange: Equatable, Hashable {
    case saveRecord(CKRecord.ID)
    case deleteRecord(CKRecord.ID)
}

/// What the delegate hands back from `nextRecordZoneChangeBatch`: the
/// materialized records for (a subset of) the pending changes. A pending
/// change the delegate leaves out of the batch is *consumed anyway* — the
/// engine passed it, the delegate declined it (the record no longer exists
/// locally, say) — mirroring CKSyncEngine's record-provider contract where
/// returning nil for an id drops its pending change.
package struct CloudRecordBatch {
    package var recordsToSave: [CKRecord]
    package var recordIDsToDelete: [CKRecord.ID]

    package init(recordsToSave: [CKRecord] = [], recordIDsToDelete: [CKRecord.ID] = []) {
        self.recordsToSave = recordsToSave
        self.recordIDsToDelete = recordIDsToDelete
    }
}

// MARK: Events

package enum CloudAccountChange: Equatable {
    case signIn
    case signOut
    case switchAccounts
}

/// Why the server says the zone is gone. All three mean the same thing to
/// the transport — its bookkeeping describes records that no longer exist —
/// but `encryptedDataReset` additionally means the user rotated their
/// iCloud keys and *wants* re-upload of everything.
package enum CloudZoneDeletionReason: Equatable {
    case deleted
    case purged
    case encryptedDataReset
}

/// Why one record save failed, sent-changes reporting. The value mirror of
/// the `CKError` codes the delegate flow actually branches on; anything
/// retryable (network, throttling, quota) never reaches the delegate as a
/// per-record failure — the engine keeps it pending and retries on its own
/// schedule, which is the queue-survives-failure guarantee (#121).
package enum CloudSaveFailure {
    /// The server holds a version this save wasn't based on (its change tag
    /// is stale or missing). Carries the server's copy: resolution is to
    /// re-encode the local winner *onto that copy* — codec `apply(_:to:)` —
    /// and re-queue, never to retry the rejected instance.
    case conflict(serverRecord: CKRecord)
    /// The zone doesn't exist (first run before zone creation, or deleted
    /// out from under us). Queue a zone save and re-queue the record.
    case zoneNotFound
    /// The record was deleted on the server after this save was based on
    /// it. The local edit still wins locally — re-queue as a fresh create
    /// (the SyncEngine "deleted there since the pull" precedent).
    case unknownItem
}

package struct CloudFailedSave {
    package let record: CKRecord
    package let failure: CloudSaveFailure

    package init(record: CKRecord, failure: CloudSaveFailure) {
        self.record = record
        self.failure = failure
    }
}

/// A record deletion a fetch delivered. The record type rides along
/// (CloudKit sends it) so the transport knows which merge primitive to
/// route to without a record-name registry lookup.
package struct CloudRecordDeletion {
    package let recordID: CKRecord.ID
    package let recordType: String

    package init(recordID: CKRecord.ID, recordType: String) {
        self.recordID = recordID
        self.recordType = recordType
    }
}

/// The value mirror of the `CKSyncEngine.Event` cases the transport handles.
/// The will/did progress events are deliberately absent — status display can
/// hang off the control calls themselves.
package enum CloudSyncEvent {
    /// New opaque engine state (pending queue + change tokens ride inside).
    /// Persist to `sync_server.ck_state` promptly; state that isn't saved
    /// is work the engine forgets it owed after relaunch.
    case stateUpdate(Data)
    case accountChange(CloudAccountChange)
    /// One fetch's record-zone deltas. Modified records arrive as the
    /// server's copies — change tag included, which is what a later save of
    /// this record must be based on.
    case fetchedRecordZoneChanges(modifications: [CKRecord], deletions: [CloudRecordDeletion])
    /// The zone itself vanished server-side.
    case zoneDeleted(reason: CloudZoneDeletionReason)
    /// One send's per-record outcomes. Saved records are the server's
    /// post-save copies (fresh change tags). Failed deletes are moot by
    /// definition — the record is already gone — and are reported only so
    /// the transport can settle its tombstone bookkeeping.
    case sentRecordZoneChanges(saved: [CKRecord], failedSaves: [CloudFailedSave],
                               deleted: [CKRecord.ID], failedDeletes: [CKRecord.ID])
}

// MARK: The two protocols

/// What the engine calls on the transport — the value mirror of
/// `CKSyncEngine.Delegate`.
package protocol CloudSyncEngineDelegate: AnyObject {
    /// Events arrive strictly in order, one at a time, awaited — state
    /// updates interleave correctly with the fetch/send results they cover.
    func handleEvent(_ event: CloudSyncEvent) async

    /// Materialize records for the next batch of pending work. `pending` is
    /// the engine's queue (or the engine's chosen batch-size prefix of it).
    /// Return nil to decline sending anything this round; the pending
    /// changes then stay queued.
    func nextRecordZoneChangeBatch(pending: [CloudPendingChange]) async -> CloudRecordBatch?
}

/// What the transport calls on the engine — the value mirror of the
/// `CKSyncEngine` handle (its `state` mutators and the manual sync calls).
package protocol CloudSyncEngineControl: AnyObject {
    /// The queued record-zone work, oldest first.
    var pendingChanges: [CloudPendingChange] { get }

    func add(pendingChanges: [CloudPendingChange])
    func remove(pendingChanges: [CloudPendingChange])

    /// Queue creation of the one custom zone (CloudKitSchema.zoneID); the
    /// next send performs it before any record work. Idempotent — saving an
    /// existing zone is a no-op, so "queue it on first connect and after
    /// any zoneNotFound/zoneDeleted" needs no am-I-sure bookkeeping.
    func addPendingZoneSave()

    /// Ask the server for deltas now. Throws only on transport failure
    /// (offline, account unavailable); everything the fetch learned arrives
    /// as events *before* the call returns.
    func fetchChanges() async throws

    /// Drain the pending queue now: zone save first, then record batches
    /// via `nextRecordZoneChangeBatch` until the queue is empty or the
    /// delegate declines. Per-record outcomes arrive as
    /// `sentRecordZoneChanges` events before the call returns; a throw is a
    /// transport failure and whatever wasn't attempted stays queued.
    func sendChanges() async throws
}
