import Foundation
import GRDB

// MARK: - Sync metadata rows (v3-sync, reshaped for CloudKit in v7–v10)

/// Which sync-tracked entity a `sync_tombstone` / `ck_record_map` row
/// concerns. Definitions and value colors are natural-key entities whose
/// record names are minted UUIDs mapped in ck_record_map; spans and label
/// sets carry their own UUIDs.
package enum SyncEntity: String {
    case span
    case labelSet = "label_set"
    case valueColor = "value_color"
    case labelDefinition = "label_definition"
}

/// A local deletion not yet pushed. `target` is the identity to delete on
/// the other side: the record name for spans and label sets, a key␟value
/// composite for value colors (their record name comes from the map).
struct SyncTombstoneRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_tombstone"
    var entity: String
    var target: String
    var deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case entity, target, deletedAt = "deleted_at"
    }
}

/// Which transport a `sync_server` row describes (v7). CloudKit is the
/// only one since #272; the historical `"server"` value (the self-hosted
/// Moment Tally server) is retired by the v10 migration, which converts
/// such a row's bookkeeping and removes it.
package enum SyncTransport: String {
    case cloudKit = "cloudkit"
}

/// The single row that *is* the sync connection. The table predates
/// CloudKit (v3-sync), which is why it is still called `sync_server` and
/// carries the self-hosted transport's columns: `url`/`userId`/`userName`
/// describe the iCloud side ("icloud", 0, account label), `ckState` holds
/// CKSyncEngine's opaque state serialization (change tokens ride inside),
/// and the checkpoint columns are dead weight the append-only migrations
/// keep. The preference sync metadata lives here because the preference
/// values themselves live in UserDefaults.
package struct SyncServerRow: Codable, FetchableRecord, PersistableRecord {
    package static let databaseTableName = "sync_server"
    package var id: Int64 = 1
    package var url: String
    package var userId: Int
    package var userName: String
    package var active = true
    package var checkpoint: Date?
    package var checkpointAfterId = 0
    package var prefsDirty = true
    package var prefsModifiedAt: Date?
    package var lastSyncedAt: Date?
    package var transport = SyncTransport.cloudKit.rawValue
    package var ckState: Data?
    /// Which CloudKit container environment the bookkeeping describes
    /// ("Development"/"Production", v9) — nil before the guard first runs.
    package var ckEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case id, url, active
        case userId = "user_id", userName = "user_name"
        case checkpoint, checkpointAfterId = "checkpoint_after_id"
        case prefsDirty = "prefs_dirty", prefsModifiedAt = "prefs_modified_at"
        case lastSyncedAt = "last_synced_at"
        case transport, ckState = "ck_state", ckEnvironment = "ck_environment"
    }
}

/// Pairs a local identity with its minted CloudKit record name (v7). Only
/// natural-key entities need rows here: a definition's key and a value
/// color's key␟value are user text, and record names travel unencrypted,
/// so their record names are minted UUIDs instead. Spans and label sets
/// carry their own UUIDs and need no mapping.
struct CloudRecordMapRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ck_record_map"
    var entity: String
    var localId: String
    var recordName: String

    enum CodingKeys: String, CodingKey {
        case entity, localId = "local_id", recordName = "record_name"
    }
}

/// What applying one fetched record did — the transport aggregates these
/// for its summary, and tests assert the merge semantics through them.
package enum RemoteApplyOutcome: Equatable {
    case inserted        // new from the other side
    case updated         // the fetched version overwrote the local row
    case localWins       // local dirty edit is newer; it will push instead
    case tombstoneWins   // deleted locally after the remote write; delete pushes
    case resurrected     // edited remotely after the local deletion; undeleted
    case deletedLocally  // a remote deletion removed the local row
    case noop
}

// MARK: - The sync surface of the local store
//
// The CloudKit-specific half (connect, the record cache, deriving the upload
// queue, the merges) lives in CloudKitSyncStore.swift; this file keeps what
// is transport-neutral: the connection row, preference metadata, and the
// tombstone/member helpers LocalBackend's own write paths share.

package extension LocalBackend {

    // MARK: Connection lifecycle

    /// The sync connection, whether active or disconnected; nil when sync
    /// was never turned on.
    func syncServer() throws -> SyncServerRow? {
        try dbQueue.read { db in try SyncServerRow.fetchOne(db) }
    }

    /// Stop syncing. Everything else — data, mappings, clean state — stays,
    /// so turning sync back on resumes instead of re-uploading the world.
    func disconnectSync() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_server SET active = 0")
        }
    }

    func recordSyncCompleted(at date: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_server SET last_synced_at = ?",
                           arguments: [date])
        }
    }

    // MARK: Preferences metadata

    /// Stamp the preferences dirty after a local preference change. A no-op
    /// until sync is turned on — with no row there is nowhere to push.
    func markPreferencesDirty(at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_server SET prefs_dirty = 1, prefs_modified_at = ?",
                arguments: [date])
        }
    }

    /// Clear the preferences dirty flag — unless another local preference
    /// edit landed since the push snapshot was taken.
    func clearPreferencesDirty(ifModifiedAt modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_server SET prefs_dirty = 0 WHERE prefs_modified_at IS ?",
                arguments: [modifiedAt])
        }
    }

    // MARK: Push bookkeeping for natural-key entities

    /// Record a successful push: clear dirty — unless the row was edited
    /// again while the push was in flight.
    func recordLabelDefinitionPushed(key: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE label_definition SET dirty = 0 WHERE key = ? AND modified_at IS ?",
                arguments: [key, modifiedAt])
        }
    }

    func recordValueColorPushed(key: String, value: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE value_color SET dirty = 0 WHERE key = ? AND value = ? AND modified_at IS ?",
                arguments: [key, value, modifiedAt])
        }
    }

    // MARK: Shared helpers (also used by LocalBackend's write paths)

    static func hasSyncServer(_ db: Database) throws -> Bool {
        try SyncServerRow.fetchOne(db) != nil
    }

    static func tombstone(entity: SyncEntity, target: String, at date: Date, _ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_tombstone (entity, target, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT (entity, target) DO UPDATE SET deleted_at = excluded.deleted_at
            """,
            arguments: [entity.rawValue, target, date])
    }

    internal static func tombstones(_ entity: SyncEntity, _ db: Database) throws -> [SyncTombstoneRow] {
        try SyncTombstoneRow
            .filter(Column("entity") == entity.rawValue)
            .order(Column("deleted_at"))
            .fetchAll(db)
    }

    static func deleteTombstone(_ entity: SyncEntity, target: String, _ db: Database) throws {
        try SyncTombstoneRow
            .filter(Column("entity") == entity.rawValue && Column("target") == target)
            .deleteAll(db)
    }

    static func members(of setId: String, _ db: Database) throws -> [SpanLabel] {
        try LabelSetMemberRow
            .filter(Column("set_id") == setId)
            .order(Column("position"))
            .fetchAll(db)
            .map { SpanLabel(key: $0.key, value: $0.value) }
    }

    static func quickMembers(of setId: String, _ db: Database) throws -> [SpanLabel] {
        try LabelSetQuickMemberRow
            .filter(Column("set_id") == setId)
            .order(Column("position"))
            .fetchAll(db)
            .map { SpanLabel(key: $0.key, value: $0.value) }
    }

    static func insert(members: [SpanLabel], setId: String, _ db: Database) throws {
        for (position, member) in members.enumerated() {
            try LabelSetMemberRow(setId: setId, position: position,
                                  key: member.key, value: member.value).insert(db)
        }
    }

    static func insert(quickMembers: [SpanLabel], setId: String, _ db: Database) throws {
        for (position, member) in quickMembers.enumerated() {
            try LabelSetQuickMemberRow(setId: setId, position: position,
                                       key: member.key, value: member.value).insert(db)
        }
    }
}
