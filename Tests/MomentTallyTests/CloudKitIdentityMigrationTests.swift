import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The v7 identity migration: existing spans are backfilled with distinct
/// UUIDs, new spans mint their own, and the sync_server row learns its
/// transport discriminator.
@Suite struct CloudKitIdentityMigrationTests {

    @Test func existingSpansAreBackfilledWithDistinctUuids() throws {
        // Build a realistic pre-v7 database, then let the full migrator
        // catch it up — the upgrade path every existing install takes.
        let dbQueue = try DatabaseQueue()
        let migrator = LocalBackend.migrator(legacyDefaults: nil)
        try migrator.migrate(dbQueue, upTo: "v6-label-set-gradient")
        try dbQueue.write { db in
            for i in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO time_span (start, note, dirty) VALUES (?, '', 1)",
                    arguments: [Date(timeIntervalSince1970: TimeInterval(i))])
            }
        }

        let backend = try LocalBackend(dbQueue, legacyDefaults: nil)
        let uuids = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM time_span")
        }
        #expect(uuids.count == 3)
        #expect(Set(uuids).count == 3)
        #expect(uuids.allSatisfy { UUID(uuidString: $0) != nil })
        _ = backend
    }

    @Test func newSpansMintTheirOwnUuid() async throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        _ = try await backend.startTimeSpan(start: Date(), labels: [], note: "")
        _ = try await backend.startTimeSpan(start: Date(), labels: [], note: "")
        let uuids = try await backend.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM time_span")
        }
        #expect(uuids.count == 2)
        #expect(Set(uuids).count == 2)
    }

    /// A pre-v7 build sharing the store can insert spans *after* the
    /// backfill ran — the uuid column is nullable in SQL, so those rows
    /// arrive with no identity. Deriving push work heals them in place
    /// instead of throwing on the NULL.
    @Test func pushWorkMintsUuidsForSpansInsertedByOlderBuilds() async throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        try backend.connectCloudKit(accountLabel: "iCloud")
        try await backend.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO time_span (start, note, dirty) VALUES (?, '', 1)",
                arguments: [Date(timeIntervalSince1970: 0)])
        }
        let work = try await backend.cloudPushWork()
        let uuids = try await backend.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM time_span")
        }
        #expect(uuids.count == 1)
        #expect(uuids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(work.saves.contains(uuids[0]))
    }

    @Test func syncServerRowDefaultsToServerTransport() throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        try backend.connectSyncServer(url: "https://sync.example",
                                      user: User(id: 1, name: "steven", admin: false))
        let row = try backend.syncServer()
        #expect(row?.transport == SyncTransport.server.rawValue)
        #expect(row?.ckState == nil)
    }
}

/// The container-environment guard (v9): the bookkeeping records *that*
/// records pushed, never *where* — a build signed for the other environment
/// must reset it rather than trivially "sync" against records that only
/// exist in the old one.
@Suite struct CloudKitEnvironmentGuardTests {

    /// A store that synced under one environment, as bookkeeping state:
    /// clean rows, a cache row, persisted engine state.
    private func syncedBackend(environment: String?) async throws -> LocalBackend {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        _ = try await backend.startTimeSpan(start: Date(), labels: [], note: "")
        try backend.connectCloudKit(accountLabel: "iCloud", environment: environment)
        try await backend.dbQueue.write { db in
            try db.execute(sql: "UPDATE time_span SET dirty = 0")
            try db.execute(sql: """
                INSERT INTO ck_record_cache (record_name, archived_record) VALUES ('r1', x'00')
                """)
            try db.execute(sql: "UPDATE sync_server SET ck_state = x'00', prefs_dirty = 0")
        }
        return backend
    }

    @Test func connectStampsTheEnvironment() throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        try backend.connectCloudKit(accountLabel: "iCloud", environment: "Production")
        #expect(try backend.syncServer()?.ckEnvironment == "Production")
    }

    @Test func nullStampIsAdoptedWithoutReset() async throws {
        let backend = try await syncedBackend(environment: nil)
        #expect(try backend.ensureCloudKitEnvironment("Production") == false)
        let row = try backend.syncServer()
        #expect(row?.ckEnvironment == "Production")
        #expect(row?.ckState != nil)
        let dirty = try await backend.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span WHERE dirty = 1")!
        }
        #expect(dirty == 0)
    }

    @Test func matchingStampIsANoop() async throws {
        let backend = try await syncedBackend(environment: "Production")
        #expect(try backend.ensureCloudKitEnvironment("Production") == false)
        #expect(try backend.syncServer()?.ckState != nil)
    }

    @Test func environmentFlipResetsBookkeeping() async throws {
        let backend = try await syncedBackend(environment: "Development")
        #expect(try backend.ensureCloudKitEnvironment("Production") == true)
        let row = try backend.syncServer()
        #expect(row?.ckEnvironment == "Production")
        #expect(row?.ckState == nil)
        #expect(row?.prefsDirty == true)
        #expect(row?.lastSyncedAt == nil)
        let (dirty, cache) = try await backend.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span WHERE dirty = 1")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ck_record_cache")!)
        }
        #expect(dirty == 1)
        #expect(cache == 0)
    }

    @Test func reconnectUnderTheOtherEnvironmentAlsoResets() async throws {
        let backend = try await syncedBackend(environment: "Development")
        try backend.connectCloudKit(accountLabel: "iCloud", environment: "Production")
        let row = try backend.syncServer()
        #expect(row?.ckEnvironment == "Production")
        #expect(row?.ckState == nil)
    }
}
