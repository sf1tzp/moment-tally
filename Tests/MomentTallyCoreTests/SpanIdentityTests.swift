import Foundation
import GRDB
import Testing
@testable import MomentTallyCore

/// The self-hosted → iCloud identity bridge (#241): spans that converged
/// through a self-hosted server adopt a record name derived from their
/// server id, so every Mac of the fleet uploads the same record instead of
/// its own copy. Since #272 the adoption runs once, in the v10 migration
/// that retires the self-hosted connection.
@Suite struct SpanIdentityTests {

    // MARK: The derivation is a fixed contract

    @Test func sha1MatchesTheReferenceVector() {
        let digest = SHA1.hash(Array("abc".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func sha1HandlesMultiBlockInput() {
        // 56 bytes: the padding spills into a second block.
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        let hex = SHA1.hash(Array(input.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    @Test func uuidV5MatchesTheReferenceVector() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        let derived = SpanIdentity.uuidV5(namespace: dns, name: "python.org")
        #expect(derived.uuidString == "886313E1-3B8A-5372-9B90-0C9AEE199E5D")
    }

    /// Pinned against an independent implementation (Python's uuid5 over
    /// the same namespace and name spelling). If this ever changes, every
    /// shipped build disagrees with the new one about span identity.
    @Test func cloudUUIDIsPinned() {
        #expect(SpanIdentity.cloudUUID(serverURL: "https://sync.example", serverId: 42)
                == "2D1E91AB-527E-54D1-B63C-6BF6A17292B9")
        #expect(SpanIdentity.cloudUUID(serverURL: "https://sync.example", serverId: 43)
                == "2D905C73-AD78-523D-8358-02EAA120106B")
        #expect(SpanIdentity.cloudUUID(serverURL: "https://other.example", serverId: 42)
                == "AEA8F67A-989B-54C4-A14D-24C967394750")
    }

    @Test func cloudUUIDIsAValidRecordName() {
        let name = SpanIdentity.cloudUUID(serverURL: "https://sync.example", serverId: 1)
        #expect(UUID(uuidString: name) != nil)
        #expect(name == name.uppercased())
    }

    @Test func urlSpellingVariantsAgree() {
        let canonical = SpanIdentity.cloudUUID(serverURL: "https://sync.example", serverId: 42)
        #expect(SpanIdentity.cloudUUID(serverURL: "https://Sync.Example/", serverId: 42) == canonical)
        #expect(SpanIdentity.cloudUUID(serverURL: " https://sync.example// ", serverId: 42) == canonical)
        #expect(SpanIdentity.cloudUUID(serverURL: "https://sync.example:8080", serverId: 42) != canonical)
    }

    // MARK: Adoption in the retirement migration (v10)

    private static let serverURL = "https://sync.example"

    /// A pre-v10 store that converged through the self-hosted server, as
    /// the migration finds it: `mapped` spans carry a sync_map row (their
    /// id on the server) and are clean, the rest were never pushed. Built
    /// against the v9 schema; opening it as a `LocalBackend` runs v10.
    private func serverDatabase(mapped: [Int], unmapped: Int, url: String = serverURL,
                                active: Bool = true) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try LocalBackend.migrator(legacyDefaults: nil).migrate(dbQueue, upTo: "v9-ck-environment")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sync_server (id, url, user_id, user_name, active, transport)
                VALUES (1, ?, 1, 'steven', ?, 'server')
                """, arguments: [url, active])
            for serverId in mapped {
                try db.execute(
                    sql: "INSERT INTO time_span (start, note, dirty, uuid) VALUES (?, '', 0, ?)",
                    arguments: [Date(timeIntervalSince1970: TimeInterval(serverId)),
                                UUID().uuidString])
                try db.execute(
                    sql: "INSERT INTO sync_map (entity, local_id, server_id) VALUES ('span', ?, ?)",
                    arguments: [String(db.lastInsertedRowID), serverId])
            }
            for i in 0..<unmapped {
                try db.execute(
                    sql: "INSERT INTO time_span (start, note, dirty, uuid) VALUES (?, '', 1, ?)",
                    arguments: [Date(timeIntervalSince1970: 1_000 + TimeInterval(i)),
                                UUID().uuidString])
            }
        }
        return dbQueue
    }

    private func uuidsByStart(_ dbQueue: DatabaseQueue) throws -> [Int: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT start, uuid FROM time_span")
            return Dictionary(uniqueKeysWithValues: rows.map {
                (Int(($0["start"] as Date).timeIntervalSince1970), $0["uuid"] as String)
            })
        }
    }

    @Test func twoMacsThatSharedAServerAgreeOnSpanIdentity() throws {
        let air = try serverDatabase(mapped: [7, 8], unmapped: 1)
        let mini = try serverDatabase(mapped: [7, 8], unmapped: 1)
        let before = try uuidsByStart(air)

        _ = try LocalBackend(air, legacyDefaults: nil)
        _ = try LocalBackend(mini, legacyDefaults: nil)

        let airUUIDs = try uuidsByStart(air)
        let miniUUIDs = try uuidsByStart(mini)
        #expect(airUUIDs[7] == miniUUIDs[7])
        #expect(airUUIDs[8] == miniUUIDs[8])
        #expect(airUUIDs[7] != airUUIDs[8])
        #expect(airUUIDs[7] == SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7))
        // The mapped spans were re-keyed; the unpushed one keeps its own.
        #expect(airUUIDs[7] != before[7])
        #expect(airUUIDs[1_000] == before[1_000])
        #expect(airUUIDs[1_000] != miniUUIDs[1_000])
    }

    @Test func adoptionCoversAServerDisconnectedBeforeTheUpgrade() throws {
        // The row survives a disconnect (inactive), and so does sync_map —
        // the identity is still there to adopt.
        let dbQueue = try serverDatabase(mapped: [7], unmapped: 0, active: false)
        _ = try LocalBackend(dbQueue, legacyDefaults: nil)
        #expect(try uuidsByStart(dbQueue)[7]
                == SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7))
    }

    @Test func retirementLeavesSyncOffAndTheFirstICloudConnectStartsOver() async throws {
        let dbQueue = try serverDatabase(mapped: [7], unmapped: 1)
        let backend = try LocalBackend(dbQueue, legacyDefaults: nil)
        let (maps, row) = try await dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_map")!,
             try SyncServerRow.fetchOne(db))
        }
        #expect(maps == 0)
        #expect(row == nil)

        try backend.connectCloudKit(accountLabel: "iCloud")
        let (dirty, connected) = try await dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span WHERE dirty = 1")!,
             try SyncServerRow.fetchOne(db))
        }
        #expect(dirty == 2)
        #expect(connected?.transport == SyncTransport.cloudKit.rawValue)
        // Identity adopted by the migration survives the connect.
        #expect(try uuidsByStart(dbQueue)[7]
                == SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7))
    }

    @Test func differentServersYieldDifferentIdentities() throws {
        let a = try serverDatabase(mapped: [7], unmapped: 0, url: "https://a.example")
        let b = try serverDatabase(mapped: [7], unmapped: 0, url: "https://b.example")
        _ = try LocalBackend(a, legacyDefaults: nil)
        _ = try LocalBackend(b, legacyDefaults: nil)
        #expect(try uuidsByStart(a)[7] != uuidsByStart(b)[7])
    }

    @Test func aStoreAlreadyOnICloudIsUntouched() async throws {
        let dbQueue = try DatabaseQueue()
        try LocalBackend.migrator(legacyDefaults: nil).migrate(dbQueue, upTo: "v9-ck-environment")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sync_server (id, url, user_id, user_name, transport, ck_state)
                VALUES (1, 'icloud', 0, 'iCloud', 'cloudkit', x'00')
                """)
            try db.execute(
                sql: "INSERT INTO time_span (start, note, dirty, uuid) VALUES (?, '', 0, ?)",
                arguments: [Date(timeIntervalSince1970: 5), UUID().uuidString])
        }
        let before = try uuidsByStart(dbQueue)
        _ = try LocalBackend(dbQueue, legacyDefaults: nil)
        let row = try await dbQueue.read { db in try SyncServerRow.fetchOne(db) }
        #expect(row?.transport == SyncTransport.cloudKit.rawValue)
        #expect(row?.ckState != nil)
        #expect(try uuidsByStart(dbQueue) == before)
    }

    @Test func reconnectingToCloudKitLeavesIdentityAlone() async throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        _ = try await backend.startTimeSpan(start: Date(timeIntervalSince1970: 5), labels: [], note: "")
        try backend.connectCloudKit(accountLabel: "iCloud")
        let before = try uuidsByStart(backend.dbQueue)
        try backend.disconnectSync()
        try backend.connectCloudKit(accountLabel: "iCloud")
        #expect(try uuidsByStart(backend.dbQueue) == before)
    }

    @Test func aNameAlreadyTakenIsNotStolen() throws {
        let dbQueue = try serverDatabase(mapped: [7], unmapped: 1)
        let taken = SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE time_span SET uuid = ? WHERE start = ?",
                           arguments: [taken, Date(timeIntervalSince1970: 1_000)])
        }
        _ = try LocalBackend(dbQueue, legacyDefaults: nil)
        let uuids = try uuidsByStart(dbQueue)
        #expect(uuids[1_000] == taken)
        #expect(uuids[7] != taken)
        #expect(Set(uuids.values).count == 2)
    }
}
