import CloudKit
import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// One device: an in-memory store connected to CloudKit, a fake engine on
/// the shared container, and the real transport wired between them — the
/// CK sibling of SyncEngineTests' store+FakeSyncServer pairing.
private final class CloudDevice {
    let store: LocalBackend
    let engine: FakeCloudEngine
    let transport: CloudKitTransport
    var prefs = (colorByValue: true, menuLabelSetLimit: 5)
    var problems: [String] = []

    /// Pass `store` to relaunch an existing device: a fresh engine resumes
    /// from the persisted ck_state, a fresh transport from the store.
    init(container: FakeCloudContainer, store existing: LocalBackend? = nil) throws {
        store = try existing ?? LocalBackend(DatabaseQueue())
        try store.connectCloudKit(accountLabel: "tester")
        engine = FakeCloudEngine(container: container,
                                 state: try store.syncServer()?.ckState)
        transport = CloudKitTransport(store: store)
        transport.readPreferences = { [unowned self] in prefs }
        transport.applyPreferences = { [unowned self] in prefs = ($0, $1) }
        transport.onProblem = { [unowned self] in problems.append($0) }
        transport.engine = engine
        engine.delegate = transport
    }

    @discardableResult
    func sync() async throws -> Bool {
        try await transport.syncNow()
    }

    // MARK: Store lenses

    /// note → (uuid, dirty), covering finished and running spans alike.
    var spans: [String: (uuid: String, dirty: Bool)] {
        get throws {
            try store.dbQueue.read { db in
                var result: [String: (String, Bool)] = [:]
                for row in try TimeSpanRow.fetchAll(db) {
                    result[row.note] = (row.uuid, row.dirty)
                }
                return result
            }
        }
    }

    var dirtyRowCount: Int {
        get throws {
            try store.dbQueue.read { db in
                try ["time_span", "label_definition", "value_color", "label_set"]
                    .map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE dirty = 1")! }
                    .reduce(0, +)
            }
        }
    }

    var tombstoneCount: Int {
        get throws {
            try store.dbQueue.read { db in try SyncTombstoneRow.fetchCount(db) }
        }
    }

    func backdateSpan(uuid: String, to date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE time_span SET modified_at = ? WHERE uuid = ?",
                           arguments: [date, uuid])
        }
    }
}

@Suite struct CloudKitTransportTests {

    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    /// LWW timestamps for staged races. Offsets from *now*, not a fixed
    /// epoch: rows born via the store carry real wall-clock edit times, and
    /// a device's own pushes echo back through the next fetch — an edit
    /// backdated below its row's original stamp would (correctly) lose to
    /// its own echo. Real clocks only move forward; staged ones must too.
    private func soon(_ offsetSeconds: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: offsetSeconds + 60)
    }

    /// A device with one of everything, not yet synced.
    private func seededDevice(_ container: FakeCloudContainer) async throws -> CloudDevice {
        let device = try CloudDevice(container: container)
        try await device.store.createLabelDefinition(key: "recipe", color: "#ff9500")
        _ = try await device.store.startTimeSpan(
            start: date(1_700_000_000),
            labels: [SpanLabel(key: "recipe", value: "sourdough")], note: "running")
        let finished = try await device.store.startTimeSpan(
            start: date(1_700_000_100), labels: [], note: "finished")
        _ = try await device.store.stopTimeSpan(id: finished.id, end: date(1_700_003_600))
        try device.store.saveValueColors([ValueColorKey.join("recipe", "sourdough"): "#f7b060"])
        try device.store.saveTagSets([TagSet(id: UUID(), name: "Bakes",
                                             tags: [TagRow(key: "recipe", value: "sourdough")],
                                             symbolName: "birthday.cake")])
        return device
    }

    // MARK: Upload & convergence

    @Test func firstSyncUploadsEverythingAndSettles() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        let changed = try await a.sync()

        // def + 2 spans + value color + set + preferences
        #expect(container.recordCount == 6)
        #expect(try a.dirtyRowCount == 0)
        #expect(try a.tombstoneCount == 0)
        #expect(changed == false)   // uploads alone change nothing locally
        #expect(a.problems.isEmpty)

        // A second run owes nothing: the container never hears about it.
        let seq = container.seq
        try await a.sync()
        #expect(container.seq == seq)
        #expect(try await a.sync() == false)   // own echoes merge as noops
    }

    @Test func datasetConvergesToASecondDevice() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        a.prefs = (colorByValue: false, menuLabelSetLimit: 9)
        try a.store.markPreferencesDirty(at: date(1_700_000_200))
        try await a.sync()

        let b = try CloudDevice(container: container)
        let changed = try await b.sync()
        #expect(changed == true)

        #expect(try b.spans.keys.sorted() == ["finished", "running"])
        #expect(try b.spans["running"]?.dirty == false)
        let definitions = try await b.store.labelDefinitions()
        #expect(definitions.map(\.key) == ["recipe"])
        #expect(try b.store.loadValueColors() == [ValueColorKey.join("recipe", "sourdough"): "#f7b060"])
        let sets = try b.store.loadTagSets()
        #expect(sets.map(\.name) == ["Bakes"])
        #expect(sets.first?.tags.map { "\($0.key)=\($0.value)" } == ["recipe=sourdough"])
        #expect(b.prefs == (false, 9))
        #expect(b.problems.isEmpty)
    }

    // MARK: Last-writer-wins

    @Test func newerRemoteEditOverwritesOlderLocalDirty() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()
        let uuid = try #require(try b.spans["running"]?.uuid)

        // B edits first (older clock), A edits later and syncs first.
        _ = try await b.store.updateTimeSpan(id: try spanRowId(b, uuid: uuid),
                                             start: date(1_700_000_000), end: nil,
                                             labels: [], note: "b-edit")
        try b.backdateSpan(uuid: uuid, to: soon(500))
        _ = try await a.store.updateTimeSpan(id: try spanRowId(a, uuid: uuid),
                                             start: date(1_700_000_000), end: nil,
                                             labels: [], note: "a-edit")
        try a.backdateSpan(uuid: uuid, to: soon(900))
        try await a.sync()

        try await b.sync()
        #expect(try b.spans["a-edit"] != nil)
        #expect(try b.spans["b-edit"] == nil)
        // B's losing edit never pushed: the server still holds A's copy.
        let server = try #require(container.record(named: uuid))
        #expect(try CloudKitRecordCodec.span(from: server).note == "a-edit")
    }

    @Test func newerLocalDirtyWinsAndPushes() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()
        let uuid = try #require(try b.spans["running"]?.uuid)

        _ = try await a.store.updateTimeSpan(id: try spanRowId(a, uuid: uuid),
                                             start: date(1_700_000_000), end: nil,
                                             labels: [], note: "a-edit")
        try a.backdateSpan(uuid: uuid, to: soon(500))
        try await a.sync()
        _ = try await b.store.updateTimeSpan(id: try spanRowId(b, uuid: uuid),
                                             start: date(1_700_000_000), end: nil,
                                             labels: [], note: "b-edit")
        try b.backdateSpan(uuid: uuid, to: soon(900))

        try await b.sync()
        #expect(try b.spans["b-edit"] != nil)
        let server = try #require(container.record(named: uuid))
        #expect(try CloudKitRecordCodec.span(from: server).note == "b-edit")

        try await a.sync()
        #expect(try a.spans["b-edit"] != nil)
        #expect(a.problems.isEmpty && b.problems.isEmpty)
    }

    // MARK: Conflicts

    @Test func lostCacheHealsThroughOneConflict() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let uuid = try #require(try a.spans["running"]?.uuid)

        // Simulate a lost record cache: the next save goes out as a fresh
        // instance, conflicts, and must heal via the server copy in the
        // failure — all within one run.
        try await a.store.deleteCloudRecordCache(recordName: uuid)
        _ = try await a.store.updateTimeSpan(id: try spanRowId(a, uuid: uuid),
                                             start: date(1_700_000_000), end: nil,
                                             labels: [], note: "healed")
        try await a.sync()

        let server = try #require(container.record(named: uuid))
        #expect(try CloudKitRecordCodec.span(from: server).note == "healed")
        #expect(try a.dirtyRowCount == 0)
        #expect(a.problems.isEmpty)
    }

    // MARK: Deletions

    @Test func localDeletionPropagates() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()

        let uuid = try #require(try a.spans["finished"]?.uuid)
        try await a.store.removeTimeSpan(id: try spanRowId(a, uuid: uuid))
        try await a.sync()
        #expect(container.record(named: uuid) == nil)
        #expect(try a.tombstoneCount == 0)

        let changed = try await b.sync()
        #expect(changed == true)
        #expect(try b.spans["finished"] == nil)
    }

    @Test func dirtyEditSurvivesRemoteDeletion() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()
        let uuid = try #require(try b.spans["finished"]?.uuid)

        _ = try await b.store.updateTimeSpan(id: try spanRowId(b, uuid: uuid),
                                             start: date(1_700_000_100),
                                             end: date(1_700_003_600),
                                             labels: [], note: "survivor")
        try await a.store.removeTimeSpan(id: try spanRowId(a, uuid: uuid))
        try await a.sync()

        // B's dirty edit survives the fetched deletion and re-creates the
        // record; A resurrects it on its next fetch.
        try await b.sync()
        #expect(try b.spans["survivor"] != nil)
        #expect(container.record(named: uuid) != nil)
        try await a.sync()
        #expect(try a.spans["survivor"] != nil)
    }

    @Test func labelSetDeletionPropagates() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()
        #expect(try b.store.loadTagSets().count == 1)

        try a.store.saveTagSets([])
        try await a.sync()
        try await b.sync()
        #expect(try b.store.loadTagSets().isEmpty)
    }

    @Test func valueColorClearPropagates() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let b = try CloudDevice(container: container)
        try await b.sync()

        try a.store.saveValueColors([:])
        try await a.sync()
        #expect(try a.tombstoneCount == 0)
        try await b.sync()
        #expect(try b.store.loadValueColors().isEmpty)
    }

    // MARK: Natural-key duplicates

    @Test func independentlyMintedDefinitionsConverge() async throws {
        let container = FakeCloudContainer()
        let a = try CloudDevice(container: container)
        let b = try CloudDevice(container: container)
        try await a.store.createLabelDefinition(key: "recipe", color: "#aaaaaa")
        try await b.store.createLabelDefinition(key: "recipe", color: "#bbbbbb")
        try setDefinitionModifiedAt(a, key: "recipe", to: date(1_700_000_100))
        try setDefinitionModifiedAt(b, key: "recipe", to: date(1_700_000_200))
        // Force the duplicate: minting happens at push-work time, so make B
        // mint *before* it ever fetches A's record (as if the two devices
        // raced their first syncs).
        _ = try await b.store.cloudPushWork()

        try await a.sync()
        try await b.sync()   // fetches A's record → canonicalize + LWW
        try await a.sync()
        try await b.sync()

        // Which minted name won is a coin flip (lexicographic min of two
        // UUIDs); everything else is deterministic: one definition record
        // left, and B's newer color everywhere.
        #expect(container.recordCount == 2)   // the definition + the shared prefs singleton
        #expect(try await a.store.labelDefinitions().map(\.color) == ["#bbbbbb"])
        #expect(try await b.store.labelDefinitions().map(\.color) == ["#bbbbbb"])
        #expect(try a.dirtyRowCount == 0)
        #expect(try b.dirtyRowCount == 0)
        #expect(a.problems.isEmpty && b.problems.isEmpty)
    }

    // MARK: Preferences

    @Test func preferencesLastWriterWins() async throws {
        let container = FakeCloudContainer()
        let a = try CloudDevice(container: container)
        let b = try CloudDevice(container: container)
        a.prefs = (false, 9)
        try a.store.markPreferencesDirty(at: date(1_700_000_100))
        try await a.sync()
        try await b.sync()
        #expect(b.prefs == (false, 9))

        b.prefs = (true, 3)
        try b.store.markPreferencesDirty(at: date(1_700_000_200))
        try await b.sync()
        try await a.sync()
        #expect(a.prefs == (true, 3))
    }

    // MARK: Queue survival

    @Test func offlineRunLeavesEverythingOwed() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        container.offline = true
        await #expect(throws: FakeCloudContainer.Offline.self) {
            try await a.sync()
        }
        #expect(try a.dirtyRowCount > 0)
        #expect(container.recordCount == 0)

        container.offline = false
        try await a.sync()
        #expect(container.recordCount == 6)
        #expect(try a.dirtyRowCount == 0)
    }

    @Test func relaunchResumesWithoutConflictsOrReuploads() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        let uploadedSeq = container.seq

        // "Relaunch": new engine from persisted ck_state, new transport,
        // same store. Nothing is owed, so nothing moves.
        let a2 = try CloudDevice(container: container, store: a.store)
        try await a2.sync()
        #expect(container.seq == uploadedSeq)

        // An edit after relaunch updates in place — the cached server copy
        // carries the change tag, so no conflict.
        let uuid = try #require(try a2.spans["running"]?.uuid)
        _ = try await a2.store.updateTimeSpan(id: try spanRowId(a2, uuid: uuid),
                                              start: date(1_700_000_000), end: nil,
                                              labels: [], note: "after-relaunch")
        try await a2.sync()
        let server = try #require(container.record(named: uuid))
        #expect(try CloudKitRecordCodec.span(from: server).note == "after-relaunch")
        #expect(a2.problems.isEmpty)
    }

    // MARK: Zone lifecycle

    @Test func zoneWipeTriggersFullReupload() async throws {
        let container = FakeCloudContainer()
        let a = try await seededDevice(container)
        try await a.sync()
        #expect(container.recordCount == 6)

        container.deleteZone(reason: .encryptedDataReset)
        #expect(container.recordCount == 0)

        // One run: the fetch learns of the wipe (re-dirtying everything),
        // the same run's enqueue+send re-uploads the world.
        try await a.sync()
        #expect(container.recordCount == 6)
        #expect(try a.dirtyRowCount == 0)
    }

    // MARK: Invented definitions

    @Test func spanWithUndefinedKeyUploadsAnInventedDefinition() async throws {
        let container = FakeCloudContainer()
        let a = try CloudDevice(container: container)
        _ = try await a.store.startTimeSpan(
            start: date(1_700_000_000),
            labels: [SpanLabel(key: "undefined", value: "x")], note: "orphan")
        try await a.sync()

        let b = try CloudDevice(container: container)
        try await b.sync()
        let definitions = try await b.store.labelDefinitions()
        #expect(definitions.map(\.key) == ["undefined"])
        #expect(definitions.first?.color == CloudKitTransport.defaultKeyColor)
    }

    // MARK: Helpers

    private func spanRowId(_ device: CloudDevice, uuid: String) throws -> Int {
        try device.store.dbQueue.read { db in
            Int(try Int64.fetchOne(db, sql: "SELECT id FROM time_span WHERE uuid = ?",
                                   arguments: [uuid])!)
        }
    }

    private func setDefinitionModifiedAt(_ device: CloudDevice, key: String,
                                         to date: Date) throws {
        try device.store.dbQueue.write { db in
            try db.execute(sql: "UPDATE label_definition SET modified_at = ? WHERE key = ?",
                           arguments: [date, key])
        }
    }
}
