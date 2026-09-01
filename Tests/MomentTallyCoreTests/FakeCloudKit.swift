// Apple-only (#85): these tests drive the CloudKit framework (the fakes
// construct real CKRecords), which does not exist on Linux.
#if canImport(CloudKit)
import CloudKit
import Foundation
@testable import MomentTallyCore

// MARK: - The fake CK layer (#121)
//
// The FakeSyncServer idea repeated for CloudKit: `FakeCloudContainer` plays
// the server (one per test, shared by every device) and `FakeCloudEngine`
// plays CKSyncEngine for one device — pending queue, change-token cursor,
// opaque state serialization, and the delegate flow, delivered through the
// same `CloudSyncEngineControl`/`CloudSyncEngineDelegate` surface the real
// adapter will drive. Two engines on one container is the two-devices
// scenario.
//
// Change tags: a real server stamps `recordChangeTag`, which nothing but a
// server can set. The fake stamps a plain integer field (`fakeChangeTag`)
// on every copy it stores or hands out, and compares it on save — same
// contract, inspectable in tests: a save whose copy doesn't carry the
// server's current tag (fresh instance, or stale fetch) is a conflict, and
// the resolution is to re-encode onto the server's copy, which carries it.

final class FakeCloudContainer {
    struct Offline: Error {}

    /// When true every engine call throws `Offline` — a transport failure;
    /// pending work stays queued.
    var offline = false

    /// The custom zone exists once some engine's zone save was sent.
    private(set) var zoneExists = false

    static let changeTagKey = "fakeChangeTag"

    private var records: [CKRecord.ID: CKRecord] = [:]   // stored copies, tag stamped
    private var modSeq: [CKRecord.ID: Int] = [:]
    private var deletions: [(seq: Int, id: CKRecord.ID, recordType: String)] = []
    private var zoneDeletions: [(seq: Int, reason: CloudZoneDeletionReason)] = []
    private(set) var seq = 0

    // MARK: Server-side inspection & staging

    var recordCount: Int { records.count }

    func record(named name: String) -> CKRecord? {
        records[CKRecord.ID(recordName: name, zoneID: CloudKitSchema.zoneID)]
            .map(Self.clone)
    }

    /// Server-side zone wipe (user deleted the app's iCloud data, or reset
    /// their encryption keys). Engines discover it on their next fetch.
    func deleteZone(reason: CloudZoneDeletionReason) {
        seq += 1
        zoneDeletions.append((seq, reason))
        zoneExists = false
        records.removeAll()
        modSeq.removeAll()
        deletions.removeAll()
    }

    // MARK: The server operations (engine-internal)

    fileprivate func createZone() {
        zoneExists = true
    }

    fileprivate enum SaveOutcome {
        case saved(CKRecord)                 // the server's post-save copy
        case failed(CloudSaveFailure)
    }

    fileprivate func save(_ record: CKRecord) -> SaveOutcome {
        guard zoneExists else { return .failed(.zoneNotFound) }
        let incomingTag = record[Self.changeTagKey] as? Int
        if let stored = records[record.recordID] {
            let currentTag = stored[Self.changeTagKey] as? Int
            guard incomingTag == currentTag else {
                return .failed(.conflict(serverRecord: Self.clone(stored)))
            }
        } else if incomingTag != nil {
            // Based on a server copy, but the server record is gone.
            return .failed(.unknownItem)
        }
        seq += 1
        let stored = Self.clone(record)
        stored[Self.changeTagKey] = seq
        records[record.recordID] = stored
        modSeq[record.recordID] = seq
        return .saved(Self.clone(stored))
    }

    /// True if the record existed; false is the moot-delete case.
    fileprivate func delete(_ id: CKRecord.ID) -> Bool {
        guard zoneExists, let stored = records.removeValue(forKey: id) else {
            return false
        }
        modSeq.removeValue(forKey: id)
        seq += 1
        deletions.append((seq, id, stored.recordType))
        return true
    }

    fileprivate func zoneDeletion(since token: Int) -> CloudZoneDeletionReason? {
        zoneDeletions.last(where: { $0.seq > token })?.reason
    }

    fileprivate func changes(since token: Int)
        -> (modifications: [CKRecord], deletions: [CloudRecordDeletion]) {
        let modified = records
            .filter { modSeq[$0.key] ?? 0 > token }
            .sorted { modSeq[$0.key] ?? 0 < modSeq[$1.key] ?? 0 }
            .map { Self.clone($0.value) }
        let deleted = deletions
            .filter { $0.seq > token && records[$0.id] == nil }
            .map { CloudRecordDeletion(recordID: $0.id, recordType: $0.recordType) }
        return (modified, deleted)
    }

    private static func clone(_ record: CKRecord) -> CKRecord {
        record.copy() as! CKRecord
    }
}

// MARK: - The per-device engine

final class FakeCloudEngine: CloudSyncEngineControl {
    let container: FakeCloudContainer
    weak var delegate: (any CloudSyncEngineDelegate)?

    /// Pending changes per `nextRecordZoneChangeBatch` round, like the real
    /// engine's ~400-record operation batches.
    var batchLimit = 400

    private(set) var pendingChanges: [CloudPendingChange] = []
    private var pendingZoneSave = false
    private var token = 0

    /// The relaunch story: what `stateUpdate` events carry, and what a new
    /// engine resumes from — pending queue and change-token cursor, like
    /// CKSyncEngine's state serialization (opaque to the transport, JSON
    /// here so tests could inspect it in a pinch).
    private struct State: Codable {
        var token: Int
        var pendingZoneSave: Bool
        var saves: [String]       // record names, in queue order
        var deletes: [String]
    }

    init(container: FakeCloudContainer, state: Data? = nil) {
        self.container = container
        if let state, let decoded = try? JSONDecoder().decode(State.self, from: state) {
            token = decoded.token
            pendingZoneSave = decoded.pendingZoneSave
            pendingChanges = decoded.saves.map { .saveRecord(Self.recordID($0)) }
                + decoded.deletes.map { .deleteRecord(Self.recordID($0)) }
        }
    }

    // MARK: CloudSyncEngineControl

    func add(pendingChanges changes: [CloudPendingChange]) {
        // Re-adding an already-pending change moves it to the back, once —
        // the real engine's pending set semantics.
        pendingChanges.removeAll(where: changes.contains)
        pendingChanges.append(contentsOf: changes)
    }

    func remove(pendingChanges changes: [CloudPendingChange]) {
        pendingChanges.removeAll(where: changes.contains)
    }

    func addPendingZoneSave() {
        pendingZoneSave = true
    }

    func fetchChanges() async throws {
        guard !container.offline else { throw FakeCloudContainer.Offline() }
        if let reason = container.zoneDeletion(since: token) {
            token = container.seq
            await delegate?.handleEvent(.zoneDeleted(reason: reason))
            await emitStateUpdate()
            return
        }
        let (modifications, deletions) = container.changes(since: token)
        token = container.seq
        if !modifications.isEmpty || !deletions.isEmpty {
            await delegate?.handleEvent(.fetchedRecordZoneChanges(
                modifications: modifications, deletions: deletions))
        }
        await emitStateUpdate()
    }

    func sendChanges() async throws {
        guard !container.offline else { throw FakeCloudContainer.Offline() }
        if pendingZoneSave {
            container.createZone()
            pendingZoneSave = false
        }
        while !pendingChanges.isEmpty {
            let slice = Array(pendingChanges.prefix(batchLimit))
            guard let batch = await delegate?.nextRecordZoneChangeBatch(pending: slice) else {
                break
            }
            // Attempted (or declined) work leaves the queue; conflict
            // resolution re-adds explicitly. Mirrors the real engine, and
            // is what makes an unresolved conflict a visible re-queue
            // rather than a silent infinite retry.
            pendingChanges.removeFirst(slice.count)

            var saved: [CKRecord] = []
            var failedSaves: [CloudFailedSave] = []
            for record in batch.recordsToSave {
                switch container.save(record) {
                case .saved(let serverCopy): saved.append(serverCopy)
                case .failed(let failure):
                    failedSaves.append(CloudFailedSave(record: record, failure: failure))
                }
            }
            var deleted: [CKRecord.ID] = []
            var failedDeletes: [CKRecord.ID] = []
            for id in batch.recordIDsToDelete {
                if container.delete(id) { deleted.append(id) } else { failedDeletes.append(id) }
            }
            await delegate?.handleEvent(.sentRecordZoneChanges(
                saved: saved, failedSaves: failedSaves,
                deleted: deleted, failedDeletes: failedDeletes))
        }
        await emitStateUpdate()
    }

    // MARK: Test levers

    /// Deliver an account event, as the system would on iCloud sign-in
    /// changes.
    func deliverAccountChange(_ change: CloudAccountChange) async {
        await delegate?.handleEvent(.accountChange(change))
    }

    // MARK: State

    private func emitStateUpdate() async {
        await delegate?.handleEvent(.stateUpdate(currentState()))
    }

    private func currentState() -> Data {
        var saves: [String] = []
        var deletes: [String] = []
        for change in pendingChanges {
            switch change {
            case .saveRecord(let id): saves.append(id.recordName)
            case .deleteRecord(let id): deletes.append(id.recordName)
            }
        }
        return try! JSONEncoder().encode(State(token: token,
                                               pendingZoneSave: pendingZoneSave,
                                               saves: saves, deletes: deletes))
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: CloudKitSchema.zoneID)
    }
}
#endif
