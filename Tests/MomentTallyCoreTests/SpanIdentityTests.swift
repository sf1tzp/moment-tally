import Foundation
import GRDB
import Testing
@testable import MomentTallyCore

/// The self-hosted → iCloud identity bridge (#241): spans that converged
/// through a self-hosted server adopt a record name derived from their
/// server id, so every Mac of the fleet uploads the same record instead of
/// its own copy.
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

    // MARK: Adoption at the transport switch

    private static let serverURL = "https://sync.example"
    private static let user = User(id: 1, name: "steven", admin: false)

    /// A store that converged through the self-hosted server: `mapped`
    /// spans carry a sync_map row (their id on the server), the rest were
    /// never pushed.
    private func serverBackend(mapped: [Int], unmapped: Int,
                               url: String = serverURL) async throws -> LocalBackend {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        try backend.connectSyncServer(url: url, user: Self.user)
        for serverId in mapped {
            let span = try await backend.startTimeSpan(
                start: Date(timeIntervalSince1970: TimeInterval(serverId)), labels: [], note: "")
            try await backend.dbQueue.write { db in
                try SyncMapRow(entity: SyncEntity.span.rawValue, localId: String(span.id),
                               serverId: serverId).insert(db)
                try db.execute(sql: "UPDATE time_span SET dirty = 0 WHERE id = ?",
                               arguments: [span.id])
            }
        }
        for i in 0..<unmapped {
            _ = try await backend.startTimeSpan(
                start: Date(timeIntervalSince1970: 1_000 + TimeInterval(i)), labels: [], note: "")
        }
        return backend
    }

    private func uuidsByStart(_ backend: LocalBackend) async throws -> [Int: String] {
        try await backend.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT start, uuid FROM time_span")
            return Dictionary(uniqueKeysWithValues: rows.map {
                (Int(($0["start"] as Date).timeIntervalSince1970), $0["uuid"] as String)
            })
        }
    }

    @Test func twoMacsThatSharedAServerAgreeOnSpanIdentity() async throws {
        let air = try await serverBackend(mapped: [7, 8], unmapped: 1)
        let mini = try await serverBackend(mapped: [7, 8], unmapped: 1)
        let before = try await uuidsByStart(air)

        try air.connectCloudKit(accountLabel: "iCloud")
        try mini.connectCloudKit(accountLabel: "iCloud")

        let airUUIDs = try await uuidsByStart(air)
        let miniUUIDs = try await uuidsByStart(mini)
        #expect(airUUIDs[7] == miniUUIDs[7])
        #expect(airUUIDs[8] == miniUUIDs[8])
        #expect(airUUIDs[7] != airUUIDs[8])
        #expect(airUUIDs[7] == SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7))
        // The mapped spans were re-keyed; the unpushed one keeps its own.
        #expect(airUUIDs[7] != before[7])
        #expect(airUUIDs[1_000] == before[1_000])
        #expect(airUUIDs[1_000] != miniUUIDs[1_000])
    }

    @Test func adoptionSurvivesADisconnectFirst() async throws {
        // The documented path: turn off the server, then enable iCloud.
        let backend = try await serverBackend(mapped: [7], unmapped: 0)
        try backend.disconnectSyncServer()
        try backend.connectCloudKit(accountLabel: "iCloud")
        let uuids = try await uuidsByStart(backend)
        #expect(uuids[7] == SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7))
    }

    @Test func switchStillStartsOver() async throws {
        let backend = try await serverBackend(mapped: [7], unmapped: 1)
        try backend.connectCloudKit(accountLabel: "iCloud")
        let (maps, dirty, row) = try await backend.dbQueue.read { db in
            (try SyncMapRow.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_span WHERE dirty = 1")!,
             try SyncServerRow.fetchOne(db))
        }
        #expect(maps == 0)
        #expect(dirty == 2)
        #expect(row?.transport == SyncTransport.cloudKit.rawValue)
    }

    @Test func differentServersYieldDifferentIdentities() async throws {
        let a = try await serverBackend(mapped: [7], unmapped: 0, url: "https://a.example")
        let b = try await serverBackend(mapped: [7], unmapped: 0, url: "https://b.example")
        try a.connectCloudKit(accountLabel: "iCloud")
        try b.connectCloudKit(accountLabel: "iCloud")
        #expect(try await uuidsByStart(a)[7] != uuidsByStart(b)[7])
    }

    @Test func reconnectingToCloudKitLeavesIdentityAlone() async throws {
        let backend = try LocalBackend(DatabaseQueue(), legacyDefaults: nil)
        _ = try await backend.startTimeSpan(start: Date(timeIntervalSince1970: 5), labels: [], note: "")
        try backend.connectCloudKit(accountLabel: "iCloud")
        let before = try await uuidsByStart(backend)
        try backend.disconnectSyncServer()
        try backend.connectCloudKit(accountLabel: "iCloud")
        #expect(try await uuidsByStart(backend) == before)
    }

    @Test func aNameAlreadyTakenIsNotStolen() async throws {
        let backend = try await serverBackend(mapped: [7], unmapped: 1)
        let taken = SpanIdentity.cloudUUID(serverURL: Self.serverURL, serverId: 7)
        try await backend.dbQueue.write { db in
            try db.execute(sql: "UPDATE time_span SET uuid = ? WHERE start = ?",
                           arguments: [taken, Date(timeIntervalSince1970: 1_000)])
        }
        try backend.connectCloudKit(accountLabel: "iCloud")
        let uuids = try await uuidsByStart(backend)
        #expect(uuids[1_000] == taken)
        #expect(uuids[7] != taken)
        #expect(Set(uuids.values).count == 2)
    }
}
