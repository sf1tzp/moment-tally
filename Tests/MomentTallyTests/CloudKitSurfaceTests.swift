import CloudKit
import Foundation
import Testing
@testable import MomentTally
@testable import MomentTallyCore

// MARK: - Delegate harness

/// The transport's seat, minimally: remembers every event, and materializes
/// batches from a dictionary standing in for the local store.
private final class TestCloudDelegate: CloudSyncEngineDelegate {
    var recordsByID: [CKRecord.ID: CKRecord] = [:]
    var declineBatches = false
    private(set) var events: [CloudSyncEvent] = []

    func handleEvent(_ event: CloudSyncEvent) async {
        events.append(event)
    }

    func nextRecordZoneChangeBatch(pending: [CloudPendingChange]) async -> CloudRecordBatch? {
        if declineBatches { return nil }
        var batch = CloudRecordBatch()
        for change in pending {
            switch change {
            case .saveRecord(let id):
                if let record = recordsByID[id] { batch.recordsToSave.append(record) }
            case .deleteRecord(let id):
                batch.recordIDsToDelete.append(id)
            }
        }
        return batch
    }

    // Event sieves, for assertions.

    var lastState: Data? {
        for event in events.reversed() {
            if case .stateUpdate(let data) = event { return data }
        }
        return nil
    }

    var fetchedModifications: [CKRecord] {
        events.flatMap { event -> [CKRecord] in
            if case .fetchedRecordZoneChanges(let mods, _) = event { return mods }
            return []
        }
    }

    var fetchedDeletions: [CloudRecordDeletion] {
        events.flatMap { event -> [CloudRecordDeletion] in
            if case .fetchedRecordZoneChanges(_, let dels) = event { return dels }
            return []
        }
    }

    var fetchEventCount: Int {
        events.filter { if case .fetchedRecordZoneChanges = $0 { true } else { false } }.count
    }

    var sentEventCount: Int {
        events.filter { if case .sentRecordZoneChanges = $0 { true } else { false } }.count
    }

    var savedRecords: [CKRecord] {
        events.flatMap { event -> [CKRecord] in
            if case .sentRecordZoneChanges(let saved, _, _, _) = event { return saved }
            return []
        }
    }

    var failedSaves: [CloudFailedSave] {
        events.flatMap { event -> [CloudFailedSave] in
            if case .sentRecordZoneChanges(_, let failed, _, _) = event { return failed }
            return []
        }
    }

    var deletedIDs: [CKRecord.ID] {
        events.flatMap { event -> [CKRecord.ID] in
            if case .sentRecordZoneChanges(_, _, let deleted, _) = event { return deleted }
            return []
        }
    }

    var failedDeletes: [CKRecord.ID] {
        events.flatMap { event -> [CKRecord.ID] in
            if case .sentRecordZoneChanges(_, _, _, let failed) = event { return failed }
            return []
        }
    }

    var zoneDeletions: [CloudZoneDeletionReason] {
        events.compactMap {
            if case .zoneDeleted(let reason) = $0 { reason } else { nil }
        }
    }

    var accountChanges: [CloudAccountChange] {
        events.compactMap {
            if case .accountChange(let change) = $0 { change } else { nil }
        }
    }

    func clearEvents() { events.removeAll() }
}

/// One device: an engine wired to a harness delegate (the engine's delegate
/// reference is weak, so the pairing keeps both alive).
private final class Device {
    let engine: FakeCloudEngine
    let delegate = TestCloudDelegate()

    init(container: FakeCloudContainer, state: Data? = nil) {
        engine = FakeCloudEngine(container: container, state: state)
        engine.delegate = delegate
    }

    func queueSave(_ record: CKRecord) {
        delegate.recordsByID[record.recordID] = record
        engine.add(pendingChanges: [.saveRecord(record.recordID)])
    }

    func queueDelete(_ id: CKRecord.ID) {
        engine.add(pendingChanges: [.deleteRecord(id)])
    }
}

// MARK: - The contract

/// What the CloudKit transport (#121, next slice) gets to assume of anything
/// behind `CloudSyncEngineControl` — pinned against the fake so the ported
/// scenario matrix inherits a server-faithful stand-in: change-token
/// incremental fetch, save/tag conflict semantics with the server copy in
/// the failure, queue survival across transport failures and relaunch, and
/// zone/account lifecycle events.
@Suite struct CloudKitSurfaceTests {

    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    private func span(uuid: String = UUID().uuidString, note: String,
                      modifiedAt epochSeconds: Int = 1_700_000_000) -> CloudSpan {
        CloudSpan(uuid: uuid, start: date(1_700_000_000), end: date(1_700_003_600),
                  note: note, labels: [SpanLabel(key: "recipe", value: "sourdough")],
                  modifiedAt: date(epochSeconds))
    }

    /// A container with the zone already saved, via a throwaway engine —
    /// most tests start past first-connect.
    private func containerWithZone() async throws -> FakeCloudContainer {
        let container = FakeCloudContainer()
        let device = Device(container: container)
        device.engine.addPendingZoneSave()
        try await device.engine.sendChanges()
        return container
    }

    // MARK: Convergence & change tokens

    @Test func saveTravelsToTheOtherDevice() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b = Device(container: container)

        let original = span(note: "kneading")
        a.queueSave(CloudKitRecordCodec.record(for: original))
        try await a.engine.sendChanges()
        #expect(a.delegate.savedRecords.count == 1)
        #expect(a.engine.pendingChanges.isEmpty)

        try await b.engine.fetchChanges()
        let received = try #require(b.delegate.fetchedModifications.first)
        #expect(try CloudKitRecordCodec.span(from: received) == original)
    }

    @Test func incrementalFetchDeliversOnlyWhatIsNew() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b = Device(container: container)

        a.queueSave(CloudKitRecordCodec.record(for: span(note: "first")))
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()
        #expect(b.delegate.fetchedModifications.count == 1)

        // Nothing new: no fetch event at all.
        b.delegate.clearEvents()
        try await b.engine.fetchChanges()
        #expect(b.delegate.fetchEventCount == 0)

        // One more save: exactly that record arrives.
        let second = span(note: "second")
        a.queueSave(CloudKitRecordCodec.record(for: second))
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()
        let received = try #require(b.delegate.fetchedModifications.first)
        #expect(try CloudKitRecordCodec.span(from: received) == second)
    }

    @Test func ownSaveEchoesBackThroughFetch() async throws {
        // Like the real change feed, a device's own pushes come back on its
        // next fetch — the merge layer's clean-row noop path absorbs them.
        let container = try await containerWithZone()
        let a = Device(container: container)
        a.queueSave(CloudKitRecordCodec.record(for: span(note: "echo")))
        try await a.engine.sendChanges()
        try await a.engine.fetchChanges()
        #expect(a.delegate.fetchedModifications.count == 1)
    }

    // MARK: Conflicts

    @Test func freshInstanceOverExistingRecordConflicts() async throws {
        // The codec's re-encode-onto-fetched rule, enforced: a fresh
        // CKRecord carries no change tag, so saving it where the server
        // already holds that record is a conflict — resolved by applying
        // the payload onto the server's copy from the failure.
        let container = try await containerWithZone()
        let a = Device(container: container)
        let uuid = UUID().uuidString

        a.queueSave(CloudKitRecordCodec.record(for: span(uuid: uuid, note: "v1")))
        try await a.engine.sendChanges()

        let v2 = span(uuid: uuid, note: "v2", modifiedAt: 1_700_000_100)
        a.queueSave(CloudKitRecordCodec.record(for: v2))
        try await a.engine.sendChanges()
        #expect(a.engine.pendingChanges.isEmpty)   // consumed, not retried
        let failed = try #require(a.delegate.failedSaves.first)
        guard case .conflict(let serverRecord) = failed.failure else {
            Issue.record("expected a conflict, got \(failed.failure)")
            return
        }
        #expect(try CloudKitRecordCodec.span(from: serverRecord).note == "v1")

        a.delegate.clearEvents()
        CloudKitRecordCodec.apply(v2, to: serverRecord)
        a.queueSave(serverRecord)
        try await a.engine.sendChanges()
        #expect(a.delegate.failedSaves.isEmpty)
        let stored = try #require(container.record(named: uuid))
        #expect(try CloudKitRecordCodec.span(from: stored) == v2)
    }

    @Test func staleCopyLosesToTheFasterDevice() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b = Device(container: container)
        let uuid = UUID().uuidString

        a.queueSave(CloudKitRecordCodec.record(for: span(uuid: uuid, note: "v1")))
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()
        let bCopy = try #require(b.delegate.fetchedModifications.first)

        // A edits on top of its post-save copy and wins the race.
        let aCopy = try #require(a.delegate.savedRecords.first)
        CloudKitRecordCodec.apply(span(uuid: uuid, note: "a-edit"), to: aCopy)
        a.queueSave(aCopy)
        try await a.engine.sendChanges()
        #expect(a.delegate.failedSaves.isEmpty)

        // B's copy is now stale: conflict, carrying A's version.
        CloudKitRecordCodec.apply(span(uuid: uuid, note: "b-edit"), to: bCopy)
        b.queueSave(bCopy)
        try await b.engine.sendChanges()
        let failed = try #require(b.delegate.failedSaves.first)
        guard case .conflict(let serverRecord) = failed.failure else {
            Issue.record("expected a conflict, got \(failed.failure)")
            return
        }
        #expect(try CloudKitRecordCodec.span(from: serverRecord).note == "a-edit")
    }

    @Test func saveOverServerDeletionFailsAsUnknownItem() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b = Device(container: container)
        let uuid = UUID().uuidString
        let recordID = CKRecord.ID(recordName: uuid, zoneID: CloudKitSchema.zoneID)

        a.queueSave(CloudKitRecordCodec.record(for: span(uuid: uuid, note: "v1")))
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()
        let bCopy = try #require(b.delegate.fetchedModifications.first)

        a.queueDelete(recordID)
        try await a.engine.sendChanges()

        b.queueSave(bCopy)
        try await b.engine.sendChanges()
        let failed = try #require(b.delegate.failedSaves.first)
        guard case .unknownItem = failed.failure else {
            Issue.record("expected unknownItem, got \(failed.failure)")
            return
        }
    }

    // MARK: Deletions

    @Test func deletionPropagatesWithItsRecordType() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b = Device(container: container)
        let uuid = UUID().uuidString
        let recordID = CKRecord.ID(recordName: uuid, zoneID: CloudKitSchema.zoneID)

        a.queueSave(CloudKitRecordCodec.record(for: span(uuid: uuid, note: "doomed")))
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()

        a.queueDelete(recordID)
        try await a.engine.sendChanges()
        #expect(a.delegate.deletedIDs == [recordID])

        b.delegate.clearEvents()
        try await b.engine.fetchChanges()
        let deletion = try #require(b.delegate.fetchedDeletions.first)
        #expect(deletion.recordID == recordID)
        #expect(deletion.recordType == CloudKitSchema.RecordType.span)
    }

    @Test func mootDeletionReportsAsFailedDelete() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let recordID = CKRecord.ID(recordName: UUID().uuidString,
                                   zoneID: CloudKitSchema.zoneID)
        a.queueDelete(recordID)
        try await a.engine.sendChanges()
        #expect(a.delegate.failedDeletes == [recordID])
        #expect(a.engine.pendingChanges.isEmpty)
    }

    // MARK: Queue survival

    @Test func offlineSendThrowsAndKeepsTheQueue() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        a.queueSave(CloudKitRecordCodec.record(for: span(note: "queued")))

        container.offline = true
        await #expect(throws: FakeCloudContainer.Offline.self) {
            try await a.engine.sendChanges()
        }
        #expect(a.engine.pendingChanges.count == 1)

        container.offline = false
        try await a.engine.sendChanges()
        #expect(a.delegate.savedRecords.count == 1)
        #expect(container.recordCount == 1)
    }

    @Test func stateSerializationResumesQueueAndCursor() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let b1 = Device(container: container)

        // B1 sees the first record, then queues work it never sends.
        let first = span(note: "first")
        a.queueSave(CloudKitRecordCodec.record(for: first))
        try await a.engine.sendChanges()
        try await b1.engine.fetchChanges()
        let queued = CloudKitRecordCodec.record(for: span(note: "queued"))
        b1.queueSave(queued)
        try await b1.engine.fetchChanges()   // emits state carrying the queue
        let state = try #require(b1.delegate.lastState)

        // "Relaunch": a fresh engine from that state owes the same work…
        let b2 = Device(container: container, state: state)
        #expect(b2.engine.pendingChanges == [.saveRecord(queued.recordID)])

        // …and its cursor is past what B1 already saw.
        let second = span(note: "second")
        a.queueSave(CloudKitRecordCodec.record(for: second))
        try await a.engine.sendChanges()
        try await b2.engine.fetchChanges()
        #expect(try b2.delegate.fetchedModifications.map { try CloudKitRecordCodec.span(from: $0) } == [second])

        b2.delegate.recordsByID[queued.recordID] = queued
        try await b2.engine.sendChanges()
        #expect(b2.delegate.savedRecords.count == 1)
    }

    // MARK: Zone lifecycle

    @Test func savesFailUntilTheZoneIsSaved() async throws {
        let container = FakeCloudContainer()   // no zone yet
        let a = Device(container: container)
        let record = CloudKitRecordCodec.record(for: span(note: "early"))

        a.queueSave(record)
        try await a.engine.sendChanges()
        let failed = try #require(a.delegate.failedSaves.first)
        guard case .zoneNotFound = failed.failure else {
            Issue.record("expected zoneNotFound, got \(failed.failure)")
            return
        }

        a.delegate.clearEvents()
        a.engine.addPendingZoneSave()
        a.queueSave(record)
        try await a.engine.sendChanges()
        #expect(a.delegate.failedSaves.isEmpty)
        #expect(a.delegate.savedRecords.count == 1)
    }

    @Test func serverSideZoneWipeArrivesAsZoneDeleted() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        a.queueSave(CloudKitRecordCodec.record(for: span(note: "doomed")))
        try await a.engine.sendChanges()

        container.deleteZone(reason: .encryptedDataReset)
        a.delegate.clearEvents()
        try await a.engine.fetchChanges()
        #expect(a.delegate.zoneDeletions == [.encryptedDataReset])
        #expect(a.delegate.fetchEventCount == 0)
        #expect(container.recordCount == 0)
    }

    // MARK: Batching & delegate contract

    @Test func sendsInBatchesOfTheEngineLimit() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        a.engine.batchLimit = 1
        for index in 0..<3 {
            a.queueSave(CloudKitRecordCodec.record(for: span(note: "batch \(index)")))
        }
        try await a.engine.sendChanges()
        #expect(a.delegate.sentEventCount == 3)
        #expect(container.recordCount == 3)
    }

    @Test func decliningABatchLeavesTheQueueAlone() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        a.queueSave(CloudKitRecordCodec.record(for: span(note: "held")))
        a.delegate.declineBatches = true
        try await a.engine.sendChanges()
        #expect(a.delegate.sentEventCount == 0)
        #expect(a.engine.pendingChanges.count == 1)
    }

    @Test func recordOmittedFromABatchIsConsumedNotRetried() async throws {
        // The record-provider contract: pending work the delegate can't
        // materialize (the row vanished locally) is dropped, not retried
        // forever.
        let container = try await containerWithZone()
        let a = Device(container: container)
        let recordID = CKRecord.ID(recordName: UUID().uuidString,
                                   zoneID: CloudKitSchema.zoneID)
        a.engine.add(pendingChanges: [.saveRecord(recordID)])   // no record behind it
        try await a.engine.sendChanges()
        #expect(a.delegate.sentEventCount == 1)
        #expect(a.delegate.savedRecords.isEmpty)
        #expect(a.engine.pendingChanges.isEmpty)
    }

    @Test func reAddingAPendingChangeKeepsOneEntry() async throws {
        let container = try await containerWithZone()
        let a = Device(container: container)
        let record = CloudKitRecordCodec.record(for: span(note: "once"))
        a.queueSave(record)
        a.queueSave(record)
        #expect(a.engine.pendingChanges == [.saveRecord(record.recordID)])
    }

    // MARK: Account events

    @Test func accountChangesReachTheDelegate() async throws {
        let container = FakeCloudContainer()
        let a = Device(container: container)
        await a.engine.deliverAccountChange(.signOut)
        #expect(a.delegate.accountChanges == [.signOut])
    }
}
