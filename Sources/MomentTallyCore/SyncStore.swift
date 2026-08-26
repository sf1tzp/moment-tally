import Foundation
import GRDB

// MARK: - Sync metadata rows (v3-sync)

/// Which sync-tracked entity a `sync_map` / `sync_tombstone` row concerns.
/// Label definitions need neither: their key is their identity on both
/// sides, and the app never deletes one locally.
package enum SyncEntity: String {
    case span
    case labelSet = "label_set"
    case valueColor = "value_color"
}

/// Pairs a local identity (span rowid as text, set UUID) with the record's
/// id on the connected server — `span_origin`, graduated.
struct SyncMapRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_map"
    var entity: String
    var localId: String
    var serverId: Int

    enum CodingKeys: String, CodingKey {
        case entity, localId = "local_id", serverId = "server_id"
    }
}

/// A local deletion not yet pushed. `target` is the server-side identity to
/// delete: a server id for spans and label sets, a key␟value composite for
/// value colors.
struct SyncTombstoneRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_tombstone"
    var entity: String
    var target: String
    var deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case entity, target, deletedAt = "deleted_at"
    }
}

/// Which transport a `sync_server` row describes (v7). Transports are
/// mutually exclusive per device in v1 (#121): connecting one wipes the
/// other's bookkeeping exactly like connecting to a different server URL.
package enum SyncTransport: String {
    case server          // self-hosted Moment Tally server (SyncServerAPI)
    case cloudKit = "cloudkit"
}

/// The single row that *is* the sync connection: server, account, timespan
/// pull checkpoint, and the preference sync metadata (the preference values
/// themselves live in UserDefaults). The device token lives in the Keychain.
/// For the CloudKit transport (v7) `url`/`userId`/`userName` describe the
/// iCloud side ("icloud", 0, account label) and `ckState` holds CKSyncEngine's
/// opaque state serialization — change tokens ride inside it, so the
/// self-hosted checkpoint columns stay untouched.
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
    package var transport = SyncTransport.server.rawValue
    package var ckState: Data?

    enum CodingKeys: String, CodingKey {
        case id, url, active
        case userId = "user_id", userName = "user_name"
        case checkpoint, checkpointAfterId = "checkpoint_after_id"
        case prefsDirty = "prefs_dirty", prefsModifiedAt = "prefs_modified_at"
        case lastSyncedAt = "last_synced_at"
        case transport, ckState = "ck_state"
    }
}

/// Pairs a local identity with its minted CloudKit record name (v7) — the
/// CK-transport sibling of `sync_map`. Only natural-key entities need rows
/// here: a definition's key and a value color's key␟value are user text,
/// and record names travel unencrypted, so their record names are minted
/// UUIDs instead. Spans and label sets carry their own UUIDs and need no
/// mapping.
struct CloudRecordMapRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ck_record_map"
    var entity: String
    var localId: String
    var recordName: String

    enum CodingKeys: String, CodingKey {
        case entity, localId = "local_id", recordName = "record_name"
    }
}

// MARK: - Push work items
//
// The snapshot merges below apply every remote-wins outcome to the store and
// return these — the records where the local copy won (or was never pushed)
// and now needs to travel up. The engine performs the network calls and
// reports back via the record*Pushed methods, which clear dirty only if the
// row wasn't edited again mid-push.

package struct SpanPush {
    package let localId: Int64
    package let serverId: Int?      // nil: create on the server, then map
    package let start: Date
    package let end: Date?
    package let note: String
    package let labels: [SpanLabel]
    package let modifiedAt: Date?
}

package struct LabelDefinitionPush {
    package let key: String
    package let color: String
    package let existsOnServer: Bool
    package let modifiedAt: Date?
}

package struct ValueColorPush {
    package let key: String
    package let value: String
    package let color: String
    package let modifiedAt: Date?
}

package struct LabelSetPush {
    package let localId: String
    package let serverId: Int?      // nil: create on the server, then map
    package let name: String
    package let symbolName: String
    package let labels: [SpanLabel]
    package let quickLabels: [SpanLabel]
    package let position: Int
    package let modifiedAt: Date?
}

/// What applying one pulled timespan did — the engine aggregates these for
/// its summary, and tests assert the merge semantics through them.
package enum RemoteApplyOutcome: Equatable {
    case inserted        // new from the server
    case updated         // server version overwrote the local row
    case localWins       // local dirty edit is newer; it will push instead
    case tombstoneWins   // deleted locally after the server write; delete pushes
    case resurrected     // server edited after the local deletion; undeleted
    case deletedLocally  // a server deletion removed the local row
    case noop
}

// MARK: - The sync surface of the local store

package extension LocalBackend {

    // MARK: Connection lifecycle

    /// The sync connection, whether active or disconnected; nil when no
    /// server was ever connected (or a different-server connect wiped it).
    func syncServer() throws -> SyncServerRow? {
        try dbQueue.read { db in try SyncServerRow.fetchOne(db) }
    }

    /// Establish (or re-activate) the sync connection. Reconnecting to the
    /// same URL resumes with mappings and clean/dirty state intact; a
    /// different URL starts over — mappings, tombstones, and the checkpoint
    /// belong to the old server, and every record becomes dirty again so
    /// the full local dataset pushes to the new one.
    func connectSyncServer(url: String, user: User) throws {
        try dbQueue.write { db in
            if var existing = try SyncServerRow.fetchOne(db), existing.url == url {
                existing.active = true
                existing.userId = user.id
                existing.userName = user.name
                try existing.update(db)
                return
            }
            try SyncMapRow.deleteAll(db)
            try SyncTombstoneRow.deleteAll(db)
            try SyncServerRow.deleteAll(db)
            for table in ["time_span", "label_definition", "value_color", "label_set"] {
                try db.execute(sql: "UPDATE \(table) SET dirty = 1")
            }
            try SyncServerRow(url: url, userId: user.id, userName: user.name).insert(db)
        }
    }

    /// Stop syncing. Everything else — data, mappings, clean state — stays,
    /// so a later reconnect to the same server resumes cleanly.
    func disconnectSyncServer() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_server SET active = 0")
        }
    }

    func advanceCheckpoint(_ checkpoint: Date, afterId: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_server SET checkpoint = ?, checkpoint_after_id = ?",
                arguments: [checkpoint, afterId])
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
    /// until a server is connected — with no row there is nowhere to push.
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

    // MARK: Timespans — applying the pulled delta feed

    /// Merge one pulled timespan, deciding against the row's *current* state
    /// inside the transaction so a concurrent local edit can't be clobbered.
    /// Last-writer-wins: the server version applies unless the local row is
    /// dirty with a strictly newer local edit time (ties go to the server —
    /// deterministic, and its copy is the one other devices already have).
    func applyRemoteSpan(_ remote: RemoteTimeSpan) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            if let map = try Self.map(.span, serverId: remote.id, db) {
                guard let localId = Int64(map.localId),
                      var row = try TimeSpanRow.fetchOne(db, key: localId) else {
                    // Orphaned mapping (shouldn't happen — deletion retires
                    // the mapping with the row): drop it and re-insert.
                    try Self.deleteMap(.span, serverId: remote.id, db)
                    try Self.insertCleanSpan(remote, db)
                    return .inserted
                }
                if row.dirty, (row.modifiedAt ?? .distantPast) > remote.updatedAt {
                    return .localWins
                }
                if !row.dirty {
                    // Usually our own push echoing back through the feed —
                    // don't report a change that isn't one.
                    let currentLabels = try SpanLabelRow
                        .filter(Column("span_id") == row.id!)
                        .order(Column("rowid"))
                        .fetchAll(db)
                        .map { SpanLabel(key: $0.key, value: $0.value) }
                    if row.start == remote.start && row.end == remote.end
                        && row.note == remote.note && currentLabels == remote.labels {
                        return .noop
                    }
                }
                row.start = remote.start
                row.end = remote.end
                row.note = remote.note
                row.dirty = false
                try row.update(db)
                try SpanLabelRow.filter(Column("span_id") == row.id!).deleteAll(db)
                try Self.insert(labels: remote.labels, spanId: row.id!, db)
                return .updated
            }
            if let tombstone = try SyncTombstoneRow
                .filter(Column("entity") == SyncEntity.span.rawValue
                    && Column("target") == String(remote.id))
                .fetchOne(db) {
                guard remote.updatedAt > tombstone.deletedAt else {
                    return .tombstoneWins
                }
                // Edited elsewhere after the local deletion: the edit wins.
                _ = try tombstone.delete(db)
                try Self.insertCleanSpan(remote, db)
                return .resurrected
            }
            try Self.insertCleanSpan(remote, db)
            return .inserted
        }
    }

    /// Merge one pulled deletion. A dirty local row with an edit newer than
    /// the deletion survives — unmapped, so the push re-creates it under a
    /// fresh server id.
    func applyRemoteSpanDeletion(_ deletion: RemoteDeletion) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            // If this device deleted it too, the tombstone is moot.
            try SyncTombstoneRow
                .filter(Column("entity") == SyncEntity.span.rawValue
                    && Column("target") == String(deletion.id))
                .deleteAll(db)
            guard let map = try Self.map(.span, serverId: deletion.id, db) else {
                return .noop
            }
            try Self.deleteMap(.span, serverId: deletion.id, db)
            guard let localId = Int64(map.localId),
                  let row = try TimeSpanRow.fetchOne(db, key: localId) else {
                return .noop
            }
            if row.dirty, (row.modifiedAt ?? .distantPast) > deletion.deletedAt {
                return .localWins
            }
            _ = try row.delete(db)
            return .deletedLocally
        }
    }

    // MARK: Timespans — pushing

    func pendingSpanPushes() async throws -> [SpanPush] {
        try await dbQueue.read { db in
            let rows = try TimeSpanRow
                .filter(Column("dirty") == true)
                .order(Column("id"))
                .fetchAll(db)
            let spans = try Self.spans(for: rows, db)
            let labelsById = Dictionary(uniqueKeysWithValues: spans.map { (Int64($0.id), $0.labels) })
            return try rows.map { row in
                let map = try Self.map(.span, localId: String(row.id!), db)
                return SpanPush(localId: row.id!,
                                serverId: map?.serverId,
                                start: row.start,
                                end: row.end,
                                note: row.note,
                                labels: labelsById[row.id!] ?? [],
                                modifiedAt: row.modifiedAt)
            }
        }
    }

    /// Record a successful push: map the server id and clear dirty — unless
    /// the row was edited again while the push was in flight.
    func recordSpanPushed(localId: Int64, serverId: Int, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try Self.upsertMap(.span, localId: String(localId), serverId: serverId, db)
            try db.execute(
                sql: "UPDATE time_span SET dirty = 0 WHERE id = ? AND modified_at IS ?",
                arguments: [localId, modifiedAt])
        }
    }

    func spanTombstones() async throws -> [(serverId: Int, deletedAt: Date)] {
        try await dbQueue.read { db in
            try Self.tombstones(.span, db).compactMap { row in
                Int(row.target).map { ($0, row.deletedAt) }
            }
        }
    }

    func removeSpanTombstone(serverId: Int) async throws {
        try await dbQueue.write { db in
            try Self.deleteTombstone(.span, target: String(serverId), db)
        }
    }

    // MARK: Label definitions — snapshot merge

    /// Merge the server's definition snapshot. Applies server wins locally
    /// (including mirror-deleting keys the server dropped) and returns the
    /// pushes where the local copy won.
    func mergeRemoteLabelDefinitions(_ remote: [RemoteLabelDefinition]) async throws
        -> (pushes: [LabelDefinitionPush], changed: Bool) {
        try await dbQueue.write { db in
            var pushes: [LabelDefinitionPush] = []
            var changed = false
            let localRows = try Row.fetchAll(
                db, sql: "SELECT key, color, dirty, modified_at FROM label_definition")
            var locals: [String: (color: String, dirty: Bool, modifiedAt: Date?)] = [:]
            for row in localRows {
                locals[row["key"]] = (row["color"], row["dirty"], row["modified_at"])
            }

            let remoteKeys = Set(remote.map(\.key))
            for definition in remote {
                guard let local = locals[definition.key] else {
                    try db.execute(
                        sql: "INSERT INTO label_definition (key, color, dirty) VALUES (?, ?, 0)",
                        arguments: [definition.key, definition.color])
                    changed = true
                    continue
                }
                if local.dirty, (local.modifiedAt ?? .distantPast) > definition.updatedAt {
                    pushes.append(LabelDefinitionPush(
                        key: definition.key, color: local.color,
                        existsOnServer: true, modifiedAt: local.modifiedAt))
                } else if local.color != definition.color || local.dirty {
                    try db.execute(
                        sql: "UPDATE label_definition SET color = ?, dirty = 0 WHERE key = ?",
                        arguments: [definition.color, definition.key])
                    changed = changed || local.color != definition.color
                }
            }

            for (key, local) in locals where !remoteKeys.contains(key) {
                if local.dirty {
                    // Never pushed (or deleted server-side after a local
                    // edit): create it there.
                    pushes.append(LabelDefinitionPush(
                        key: key, color: local.color,
                        existsOnServer: false, modifiedAt: local.modifiedAt))
                } else {
                    // The server (via another client) deleted the key; the
                    // local copy was in sync, so mirror the deletion. Clean
                    // value colors of the key follow; dirty ones stay and
                    // re-create the definition when they push.
                    try db.execute(sql: "DELETE FROM label_definition WHERE key = ?",
                                   arguments: [key])
                    try db.execute(sql: "DELETE FROM value_color WHERE key = ? AND dirty = 0",
                                   arguments: [key])
                    changed = true
                }
            }
            return (pushes, changed)
        }
    }

    func recordLabelDefinitionPushed(key: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE label_definition SET dirty = 0 WHERE key = ? AND modified_at IS ?",
                arguments: [key, modifiedAt])
        }
    }

    /// Every locally known definition key — the engine uses this to create
    /// definitions for label keys that dirty spans or value colors
    /// reference but no definition covers.
    func definitionKeys() async throws -> Set<String> {
        try await dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT key FROM label_definition"))
        }
    }

    /// Insert a definition already known to the server (engine-created as a
    /// prerequisite for a span or color push): born clean.
    func insertCleanDefinition(key: String, color: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO label_definition (key, color, dirty) VALUES (?, ?, 0)",
                arguments: [key, color])
        }
    }

    // MARK: Value colors — snapshot merge

    func mergeRemoteValueColors(_ remote: [RemoteLabelDefinition]) async throws
        -> (pushes: [ValueColorPush], changed: Bool) {
        try await dbQueue.write { db in
            var pushes: [ValueColorPush] = []
            var changed = false
            var remotes: [String: (key: String, value: String, color: String, updatedAt: Date)] = [:]
            for definition in remote {
                for valueColor in definition.valueColors {
                    remotes[ValueColorKey.join(definition.key, valueColor.value)] =
                        (definition.key, valueColor.value, valueColor.color, valueColor.updatedAt)
                }
            }
            let localRows = try ValueColorRow.fetchAll(db)
            var locals: [String: ValueColorRow] = [:]
            for row in localRows {
                locals[ValueColorKey.join(row.key, row.value)] = row
            }

            for (composite, entry) in remotes {
                guard var local = locals[composite] else {
                    if let tombstone = try SyncTombstoneRow
                        .filter(Column("entity") == SyncEntity.valueColor.rawValue
                            && Column("target") == composite)
                        .fetchOne(db) {
                        if entry.updatedAt > tombstone.deletedAt {
                            _ = try tombstone.delete(db)
                            try ValueColorRow(key: entry.key, value: entry.value,
                                              color: entry.color, dirty: false,
                                              modifiedAt: nil).insert(db)
                            changed = true
                        }
                        // else: the local clear is newer; the engine pushes it.
                        continue
                    }
                    try ValueColorRow(key: entry.key, value: entry.value,
                                      color: entry.color, dirty: false,
                                      modifiedAt: nil).insert(db)
                    changed = true
                    continue
                }
                if local.dirty, (local.modifiedAt ?? .distantPast) > entry.updatedAt {
                    pushes.append(ValueColorPush(key: local.key, value: local.value,
                                                 color: local.color,
                                                 modifiedAt: local.modifiedAt))
                } else if local.color != entry.color || local.dirty {
                    changed = changed || local.color != entry.color
                    local.color = entry.color
                    local.dirty = false
                    try local.update(db)
                }
            }

            for (composite, local) in locals where remotes[composite] == nil {
                if local.dirty {
                    pushes.append(ValueColorPush(key: local.key, value: local.value,
                                                 color: local.color,
                                                 modifiedAt: local.modifiedAt))
                } else {
                    _ = try local.delete(db)   // cleared on the server; mirror
                    changed = true
                }
            }
            return (pushes, changed)
        }
    }

    func recordValueColorPushed(key: String, value: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE value_color SET dirty = 0 WHERE key = ? AND value = ? AND modified_at IS ?",
                arguments: [key, value, modifiedAt])
        }
    }

    func valueColorTombstones() async throws -> [(key: String, value: String, deletedAt: Date)] {
        try await dbQueue.read { db in
            try Self.tombstones(.valueColor, db).compactMap { row in
                ValueColorKey.split(row.target).map { ($0.key, $0.value, row.deletedAt) }
            }
        }
    }

    func removeValueColorTombstone(key: String, value: String) async throws {
        try await dbQueue.write { db in
            try Self.deleteTombstone(.valueColor, target: ValueColorKey.join(key, value), db)
        }
    }

    // MARK: Label sets — snapshot merge

    func mergeRemoteLabelSets(_ remote: [RemoteLabelSet]) async throws
        -> (pushes: [LabelSetPush], changed: Bool) {
        try await dbQueue.write { db in
            var pushes: [LabelSetPush] = []
            var changed = false
            let maps = try SyncMapRow
                .filter(Column("entity") == SyncEntity.labelSet.rawValue)
                .fetchAll(db)
            let localByServer = Dictionary(uniqueKeysWithValues: maps.map { ($0.serverId, $0.localId) })
            let serverByLocal = Dictionary(uniqueKeysWithValues: maps.map { ($0.localId, $0.serverId) })
            let localRows = try LabelSetRow.fetchAll(db)
            let rowsById = Dictionary(uniqueKeysWithValues: localRows.map { ($0.id, $0) })
            var coveredLocalIds = Set<String>()

            for (position, remoteSet) in remote.enumerated() {
                if let localId = localByServer[remoteSet.id] {
                    coveredLocalIds.insert(localId)
                    guard var row = rowsById[localId] else {
                        // Mapped but locally deleted: the tombstone decides.
                        if let tombstone = try SyncTombstoneRow
                            .filter(Column("entity") == SyncEntity.labelSet.rawValue
                                && Column("target") == String(remoteSet.id))
                            .fetchOne(db) {
                            if remoteSet.updatedAt > tombstone.deletedAt {
                                _ = try tombstone.delete(db)
                                try Self.insertCleanLabelSet(remoteSet, localId: localId,
                                                             position: position, db)
                                changed = true
                            }
                            continue
                        }
                        // No tombstone either (orphan map): re-insert.
                        try Self.insertCleanLabelSet(remoteSet, localId: localId,
                                                     position: position, db)
                        changed = true
                        continue
                    }
                    if row.dirty, (row.modifiedAt ?? .distantPast) > remoteSet.updatedAt {
                        pushes.append(LabelSetPush(
                            localId: row.id, serverId: remoteSet.id,
                            name: row.name, symbolName: row.symbol ?? TagSet.markSymbol,
                            labels: try Self.members(of: row.id, db),
                            quickLabels: try Self.quickMembers(of: row.id, db),
                            position: row.position, modifiedAt: row.modifiedAt))
                        continue
                    }
                    let localMembers = try Self.members(of: row.id, db)
                    let localQuick = try Self.quickMembers(of: row.id, db)
                    changed = changed
                        || row.name != remoteSet.name
                        || (row.symbol ?? TagSet.markSymbol) != remoteSet.symbolName
                        || row.position != position
                        || localMembers != remoteSet.labels
                        || localQuick != remoteSet.quickLabels
                    row.name = remoteSet.name
                    row.symbol = remoteSet.symbolName
                    row.position = position
                    row.dirty = false
                    try row.update(db)
                    try LabelSetMemberRow.filter(Column("set_id") == row.id).deleteAll(db)
                    try Self.insert(members: remoteSet.labels, setId: row.id, db)
                    try LabelSetQuickMemberRow.filter(Column("set_id") == row.id).deleteAll(db)
                    try Self.insert(quickMembers: remoteSet.quickLabels, setId: row.id, db)
                } else {
                    // Unmapped tombstones can't exist (the mapping is what
                    // names the server id), so this is new from the server.
                    let localId = UUID().uuidString
                    try Self.insertCleanLabelSet(remoteSet, localId: localId,
                                                 position: position, db)
                    try Self.upsertMap(.labelSet, localId: localId,
                                       serverId: remoteSet.id, db)
                    coveredLocalIds.insert(localId)
                    changed = true
                }
            }

            for row in localRows where !coveredLocalIds.contains(row.id) {
                if let serverId = serverByLocal[row.id] {
                    // The server dropped a set this store knew as synced.
                    try Self.deleteMap(.labelSet, serverId: serverId, db)
                    if row.dirty {
                        // Edited here since: the edit wins, re-create it.
                        pushes.append(LabelSetPush(
                            localId: row.id, serverId: nil,
                            name: row.name, symbolName: row.symbol ?? TagSet.markSymbol,
                            labels: try Self.members(of: row.id, db),
                            quickLabels: try Self.quickMembers(of: row.id, db),
                            position: row.position, modifiedAt: row.modifiedAt))
                    } else {
                        _ = try row.delete(db)
                        changed = true
                    }
                } else {
                    // Never synced: create it on the server.
                    pushes.append(LabelSetPush(
                        localId: row.id, serverId: nil,
                        name: row.name, symbolName: row.symbol ?? TagSet.markSymbol,
                        labels: try Self.members(of: row.id, db),
                        quickLabels: try Self.quickMembers(of: row.id, db),
                        position: row.position, modifiedAt: row.modifiedAt))
                }
            }
            return (pushes, changed)
        }
    }

    func recordLabelSetPushed(localId: String, serverId: Int, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try Self.upsertMap(.labelSet, localId: localId, serverId: serverId, db)
            try db.execute(
                sql: "UPDATE label_set SET dirty = 0 WHERE id = ? AND modified_at IS ?",
                arguments: [localId, modifiedAt])
        }
    }

    func labelSetTombstones() async throws -> [(serverId: Int, deletedAt: Date)] {
        try await dbQueue.read { db in
            try Self.tombstones(.labelSet, db).compactMap { row in
                Int(row.target).map { ($0, row.deletedAt) }
            }
        }
    }

    func removeLabelSetTombstone(serverId: Int) async throws {
        try await dbQueue.write { db in
            try Self.deleteTombstone(.labelSet, target: String(serverId), db)
        }
    }

    // MARK: Shared helpers (also used by LocalBackend's write paths)

    static func hasSyncServer(_ db: Database) throws -> Bool {
        try SyncServerRow.fetchOne(db) != nil
    }

    /// Record a deletion for later push — only if the record was known to
    /// the server (mapped); an unpushed record can simply vanish. Retires
    /// the mapping with the row.
    static func tombstoneIfMapped(entity: SyncEntity, localId: String, _ db: Database) throws {
        guard let map = try map(entity, localId: localId, db) else { return }
        try tombstone(entity: entity, target: String(map.serverId), at: Date(), db)
        try deleteMap(entity, serverId: map.serverId, db)
    }

    static func tombstone(entity: SyncEntity, target: String, at date: Date, _ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_tombstone (entity, target, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT (entity, target) DO UPDATE SET deleted_at = excluded.deleted_at
            """,
            arguments: [entity.rawValue, target, date])
    }

    internal static func map(_ entity: SyncEntity, serverId: Int, _ db: Database) throws -> SyncMapRow? {
        try SyncMapRow
            .filter(Column("entity") == entity.rawValue && Column("server_id") == serverId)
            .fetchOne(db)
    }

    internal static func map(_ entity: SyncEntity, localId: String, _ db: Database) throws -> SyncMapRow? {
        try SyncMapRow
            .filter(Column("entity") == entity.rawValue && Column("local_id") == localId)
            .fetchOne(db)
    }

    static func upsertMap(_ entity: SyncEntity, localId: String, serverId: Int, _ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_map (entity, local_id, server_id) VALUES (?, ?, ?)
            ON CONFLICT (entity, local_id) DO UPDATE SET server_id = excluded.server_id
            """,
            arguments: [entity.rawValue, localId, serverId])
    }

    static func deleteMap(_ entity: SyncEntity, serverId: Int, _ db: Database) throws {
        try SyncMapRow
            .filter(Column("entity") == entity.rawValue && Column("server_id") == serverId)
            .deleteAll(db)
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

    private static func insertCleanSpan(_ remote: RemoteTimeSpan, _ db: Database) throws {
        var row = TimeSpanRow(id: nil, start: remote.start, end: remote.end,
                              note: remote.note, dirty: false, modifiedAt: nil)
        try row.insert(db)
        try insert(labels: remote.labels, spanId: row.id!, db)
        try upsertMap(.span, localId: String(row.id!), serverId: remote.id, db)
    }

    private static func insertCleanLabelSet(_ remote: RemoteLabelSet, localId: String,
                                            position: Int, _ db: Database) throws {
        // color: nil — the card color is local-only, so the server has
        // nothing to say about it. (The merge's *update* path keeps the
        // local color the same way: it never assigns `row.color`.)
        try LabelSetRow(id: localId, name: remote.name, symbol: remote.symbolName,
                        color: nil, position: position, dirty: false,
                        modifiedAt: nil).insert(db)
        try insert(members: remote.labels, setId: localId, db)
        try insert(quickMembers: remote.quickLabels, setId: localId, db)
    }

    private static func members(of setId: String, _ db: Database) throws -> [SpanLabel] {
        try LabelSetMemberRow
            .filter(Column("set_id") == setId)
            .order(Column("position"))
            .fetchAll(db)
            .map { SpanLabel(key: $0.key, value: $0.value) }
    }

    private static func quickMembers(of setId: String, _ db: Database) throws -> [SpanLabel] {
        try LabelSetQuickMemberRow
            .filter(Column("set_id") == setId)
            .order(Column("position"))
            .fetchAll(db)
            .map { SpanLabel(key: $0.key, value: $0.value) }
    }

    private static func insert(members: [SpanLabel], setId: String, _ db: Database) throws {
        for (position, member) in members.enumerated() {
            try LabelSetMemberRow(setId: setId, position: position,
                                  key: member.key, value: member.value).insert(db)
        }
    }

    private static func insert(quickMembers: [SpanLabel], setId: String, _ db: Database) throws {
        for (position, member) in quickMembers.enumerated() {
            try LabelSetQuickMemberRow(setId: setId, position: position,
                                       key: member.key, value: member.value).insert(db)
        }
    }
}
