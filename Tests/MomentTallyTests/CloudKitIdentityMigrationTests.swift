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

    @Test func syncServerRowDefaultsToServerTransport() throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        try backend.connectSyncServer(url: "https://sync.example",
                                      user: User(id: 1, name: "steven", admin: false))
        let row = try backend.syncServer()
        #expect(row?.transport == SyncTransport.server.rawValue)
        #expect(row?.ckState == nil)
    }
}
