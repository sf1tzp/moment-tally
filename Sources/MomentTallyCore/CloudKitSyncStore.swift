import Foundation
import GRDB

// MARK: - CloudKit sync bookkeeping rows (v8)

/// The last server copy seen for one CloudKit record, as a full archive.
/// The server change tag rides inside: a save based on this archive updates
/// the record, a save without it conflicts. Presence here is also the
/// transport's "the server knows this record" marker — the CK sibling of a
/// `sync_map` row — which is what decides whether a local deletion leaves a
/// tombstone. Losing a row is safe: the next save goes out fresh, conflicts
/// once, and heals from the server copy carried in the failure.
struct CloudRecordCacheRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ck_record_cache"
    var recordName: String
    var archivedRecord: Data

    enum CodingKeys: String, CodingKey {
        case recordName = "record_name", archivedRecord = "archived_record"
    }
}

// MARK: - Transport-facing value shapes

/// What one CloudKit record name means locally — how the transport routes a
/// pending save back to the row that must be encoded.
package enum CloudRecordIdentity: Equatable {
    case span(uuid: String)
    case labelSet(id: String)
    case labelDefinition(key: String)
    case valueColor(key: String, value: String)
    case preferences
}

/// One run's derived upload queue: everything dirty plus every tombstone,
/// as record names. Derived fresh from the store each run — like the
/// self-hosted engine, a failed run changes nothing about what is owed, so
/// the engine's own pending queue is just transient transport machinery.
package struct CloudPushWork: Equatable {
    package var saves: [String] = []
    package var deletes: [String] = []
}

/// Merging one fetched natural-key record (definition, value color) can
/// require server-side cleanup beyond the local write: when two devices
/// independently minted records for the same key, the duplicate must go.
package struct CloudNaturalKeyMergeResult: Equatable {
    package var outcome: RemoteApplyOutcome
    /// A duplicate record for the same natural key that lost record-name
    /// canonicalization; the transport queues its deletion.
    package var duplicateRecordToDelete: String?
}

// MARK: - The CloudKit sync surface of the local store

package extension LocalBackend {

    // MARK: Connection lifecycle

    /// Establish (or re-activate) the CloudKit connection. Mirrors
    /// `connectSyncServer`: reconnecting to CloudKit resumes with mappings
    /// and clean/dirty state intact; switching from a self-hosted server
    /// starts over — its bookkeeping is wiped and every row goes dirty so
    /// the full local dataset uploads.
    func connectCloudKit(accountLabel: String) throws {
        try dbQueue.write { db in
            if var existing = try SyncServerRow.fetchOne(db),
               existing.transport == SyncTransport.cloudKit.rawValue {
                existing.active = true
                existing.userName = accountLabel
                try existing.update(db)
                return
            }
            try SyncMapRow.deleteAll(db)
            try SyncTombstoneRow.deleteAll(db)
            try CloudRecordMapRow.deleteAll(db)
            try CloudRecordCacheRow.deleteAll(db)
            try SyncServerRow.deleteAll(db)
            for table in ["time_span", "label_definition", "value_color", "label_set"] {
                try db.execute(sql: "UPDATE \(table) SET dirty = 1")
            }
            var row = SyncServerRow(url: "icloud", userId: 0, userName: accountLabel)
            row.transport = SyncTransport.cloudKit.rawValue
            try row.insert(db)
        }
    }

    /// Persist CKSyncEngine's opaque state serialization. Change tokens ride
    /// inside, so this must land promptly after every state-update event —
    /// state that isn't saved is work the engine forgets it owed.
    func saveCloudKitState(_ state: Data) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_server SET ck_state = ?", arguments: [state])
        }
    }

    /// The zone vanished server-side (deleted, purged, or the user reset
    /// their iCloud encryption keys), or the account changed under us:
    /// every piece of CK bookkeeping describes records that no longer
    /// exist. Wipe it and go dirty — the "connect to a different server"
    /// semantics — so the next run re-uploads the full local dataset.
    func resetCloudKitBookkeeping() async throws {
        try await dbQueue.write { db in
            try CloudRecordMapRow.deleteAll(db)
            try CloudRecordCacheRow.deleteAll(db)
            try SyncTombstoneRow.deleteAll(db)
            for table in ["time_span", "label_definition", "value_color", "label_set"] {
                try db.execute(sql: "UPDATE \(table) SET dirty = 1")
            }
            try db.execute(sql: """
                UPDATE sync_server SET ck_state = NULL, prefs_dirty = 1, last_synced_at = NULL
                """)
        }
    }

    // MARK: Record cache

    func cloudRecordArchive(recordName: String) async throws -> Data? {
        try await dbQueue.read { db in
            try CloudRecordCacheRow.fetchOne(db, key: recordName)?.archivedRecord
        }
    }

    func storeCloudRecordArchive(recordName: String, _ archive: Data) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO ck_record_cache (record_name, archived_record) VALUES (?, ?)
                ON CONFLICT (record_name) DO UPDATE SET archived_record = excluded.archived_record
                """, arguments: [recordName, archive])
        }
    }

    func deleteCloudRecordCache(recordName: String) async throws {
        try await dbQueue.write { db in
            _ = try CloudRecordCacheRow.deleteOne(db, key: recordName)
        }
    }

    // MARK: Identity

    /// Resolve a record name to the local row it stands for. Needed because
    /// the engine's restored pending queue survives relaunch as bare record
    /// ids. Minted names are checked first (the map is authoritative);
    /// span/set names are their rows' own UUIDs.
    func cloudIdentity(forRecordName name: String) async throws -> CloudRecordIdentity? {
        try await dbQueue.read { db in
            if name == CloudKitSchema.preferencesRecordName { return .preferences }
            if let map = try Self.ckMap(recordName: name, db) {
                switch SyncEntity(rawValue: map.entity) {
                case .labelDefinition:
                    return .labelDefinition(key: map.localId)
                case .valueColor:
                    guard let (key, value) = ValueColorKey.split(map.localId) else { return nil }
                    return .valueColor(key: key, value: value)
                default:
                    return nil
                }
            }
            if try TimeSpanRow.filter(Column("uuid") == name).fetchCount(db) > 0 {
                return .span(uuid: name)
            }
            if try LabelSetRow.filter(Column("id") == name).fetchCount(db) > 0 {
                return .labelSet(id: name)
            }
            return nil
        }
    }

    // MARK: Deriving the upload queue

    /// Definitions for label keys that dirty spans or value colors reference
    /// but no definition covers — invented with the default color, *born
    /// dirty* so they upload alongside the records that need them. (The
    /// self-hosted engine creates these because its server rejects unknown
    /// keys; CloudKit wouldn't reject, but the other devices still need the
    /// definition record to color the label.)
    func ensureCloudDefinitions(defaultColor: String) async throws {
        try await dbQueue.write { db in
            let known = Set(try String.fetchAll(db, sql: "SELECT key FROM label_definition"))
            let spanKeys = try String.fetchAll(db, sql: """
                SELECT DISTINCT l.key FROM time_span_label l
                JOIN time_span s ON s.id = l.span_id WHERE s.dirty = 1
                """)
            let colorKeys = try String.fetchAll(
                db, sql: "SELECT DISTINCT key FROM value_color WHERE dirty = 1")
            for key in Set(spanKeys).union(colorKeys).subtracting(known).sorted() {
                try db.execute(
                    sql: "INSERT INTO label_definition (key, color, dirty) VALUES (?, ?, 1)",
                    arguments: [key, defaultColor])
            }
        }
    }

    /// Snapshot the work owed: every dirty row as a pending save, every
    /// tombstone as a pending delete. Mints (and persists) record names for
    /// natural-key entities that don't have one yet, so a retried upload
    /// reuses the same name instead of scattering duplicates.
    func cloudPushWork() async throws -> CloudPushWork {
        try await dbQueue.write { db in
            var work = CloudPushWork()
            work.saves += try String.fetchAll(
                db, sql: "SELECT uuid FROM time_span WHERE dirty = 1 ORDER BY id")
            for key in try String.fetchAll(
                db, sql: "SELECT key FROM label_definition WHERE dirty = 1 ORDER BY key") {
                work.saves.append(try Self.ckMapOrMint(.labelDefinition, localId: key, db))
            }
            for row in try ValueColorRow.filter(Column("dirty") == true).fetchAll(db) {
                let composite = ValueColorKey.join(row.key, row.value)
                work.saves.append(try Self.ckMapOrMint(.valueColor, localId: composite, db))
            }
            work.saves += try String.fetchAll(
                db, sql: "SELECT id FROM label_set WHERE dirty = 1 ORDER BY position")
            if let server = try SyncServerRow.fetchOne(db), server.prefsDirty {
                work.saves.append(CloudKitSchema.preferencesRecordName)
            }

            for tombstone in try Self.tombstones(.span, db) {
                work.deletes.append(tombstone.target)      // target == record name
            }
            for tombstone in try Self.tombstones(.labelSet, db) {
                work.deletes.append(tombstone.target)      // target == record name
            }
            for tombstone in try Self.tombstones(.valueColor, db) {
                // Value-color tombstones carry the key␟value composite; the
                // record name comes from the map. No mapping means the
                // override never uploaded — nothing to delete anywhere.
                if let map = try Self.ckMap(.valueColor, ckLocalId: tombstone.target, db) {
                    work.deletes.append(map.recordName)
                } else {
                    try Self.deleteTombstone(.valueColor, target: tombstone.target, db)
                }
            }
            return work
        }
    }

    // MARK: Payloads for pending saves
    //
    // Each returns nil when the row is gone *or no longer dirty* — a fetch
    // merge may have applied the server's copy since the save was queued,
    // and pushing the server's own content back would be a wasted write.
    // A declined pending change is consumed, not retried (the surface's
    // record-provider contract), which is exactly right for both cases.

    func cloudSpanSave(uuid: String) async throws -> (span: CloudSpan, rowModifiedAt: Date?)? {
        try await dbQueue.read { db in
            guard let row = try TimeSpanRow.filter(Column("uuid") == uuid).fetchOne(db),
                  row.dirty else {
                return nil
            }
            let labels = try SpanLabelRow
                .filter(Column("span_id") == row.id!)
                .order(Column("rowid"))
                .fetchAll(db)
                .map { SpanLabel(key: $0.key, value: $0.value) }
            return (CloudSpan(uuid: uuid, start: row.start, end: row.end, note: row.note,
                              labels: labels,
                              modifiedAt: row.modifiedAt ?? .distantPast),
                    row.modifiedAt)
        }
    }

    func cloudLabelSetSave(id: String) async throws -> (set: CloudLabelSet, rowModifiedAt: Date?)? {
        try await dbQueue.read { db in
            guard let row = try LabelSetRow.fetchOne(db, key: id), row.dirty else { return nil }
            return (CloudLabelSet(uuid: id, name: row.name,
                                  symbolName: row.symbol ?? TagSet.markSymbol,
                                  labels: try Self.members(of: id, db),
                                  quickLabels: try Self.quickMembers(of: id, db),
                                  position: row.position,
                                  modifiedAt: row.modifiedAt ?? .distantPast),
                    row.modifiedAt)
        }
    }

    func cloudDefinitionSave(key: String) async throws
        -> (definition: CloudLabelDefinition, rowModifiedAt: Date?)? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT color, modified_at FROM label_definition WHERE key = ? AND dirty = 1",
                arguments: [key]) else { return nil }
            let modifiedAt: Date? = row["modified_at"]
            return (CloudLabelDefinition(key: key, color: row["color"],
                                         modifiedAt: modifiedAt ?? .distantPast),
                    modifiedAt)
        }
    }

    func cloudValueColorSave(key: String, value: String) async throws
        -> (valueColor: CloudValueColor, rowModifiedAt: Date?)? {
        try await dbQueue.read { db in
            guard let row = try ValueColorRow
                .filter(Column("key") == key && Column("value") == value)
                .fetchOne(db), row.dirty else { return nil }
            return (CloudValueColor(key: key, value: value, color: row.color,
                                    modifiedAt: row.modifiedAt ?? .distantPast),
                    row.modifiedAt)
        }
    }

    // MARK: Push bookkeeping

    func recordCloudSpanPushed(uuid: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE time_span SET dirty = 0 WHERE uuid = ? AND modified_at IS ?",
                arguments: [uuid, modifiedAt])
        }
    }

    func recordCloudLabelSetPushed(id: String, modifiedAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE label_set SET dirty = 0 WHERE id = ? AND modified_at IS ?",
                arguments: [id, modifiedAt])
        }
    }

    /// A deletion reached the server (or was moot — the record was already
    /// gone, same result): retire the tombstone, mapping, and cache row
    /// behind the record name.
    func settleCloudDeletion(recordName: String) async throws {
        try await dbQueue.write { db in
            _ = try CloudRecordCacheRow.deleteOne(db, key: recordName)
            if let map = try Self.ckMap(recordName: recordName, db) {
                if map.entity == SyncEntity.valueColor.rawValue {
                    try Self.deleteTombstone(.valueColor, target: map.localId, db)
                }
                try Self.deleteCkMap(recordName: recordName, db)
            }
            try Self.deleteTombstone(.span, target: recordName, db)
            try Self.deleteTombstone(.labelSet, target: recordName, db)
        }
    }

    // MARK: Applying fetched records — spans

    /// Merge one fetched span, `applyRemoteSpan` re-keyed on the client
    /// UUID: no sync_map, the record name *is* the row identity. Same LWW
    /// rule — the server copy applies unless the local row is dirty with a
    /// strictly newer edit; ties go to the incumbent server copy.
    func applyCloudSpan(_ remote: CloudSpan) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            if var row = try TimeSpanRow.filter(Column("uuid") == remote.uuid).fetchOne(db) {
                if row.dirty, (row.modifiedAt ?? .distantPast) > remote.modifiedAt {
                    return .localWins
                }
                if !row.dirty {
                    // Usually our own push echoing back through the fetch.
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
                    && Column("target") == remote.uuid)
                .fetchOne(db) {
                guard remote.modifiedAt > tombstone.deletedAt else {
                    return .tombstoneWins
                }
                _ = try tombstone.delete(db)
                try Self.insertCleanCloudSpan(remote, db)
                return .resurrected
            }
            try Self.insertCleanCloudSpan(remote, db)
            return .inserted
        }
    }

    /// Merge one fetched span deletion. CloudKit deletions carry no
    /// timestamp, so the LWW-against-deletion rule degrades to: *any* dirty
    /// local edit survives (and re-uploads as a fresh record); a clean row
    /// mirrors the deletion.
    func applyCloudSpanDeletion(uuid: String) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            // If this device deleted it too, its tombstone is moot; and the
            // cached server copy describes a record that no longer exists.
            try Self.deleteTombstone(.span, target: uuid, db)
            _ = try CloudRecordCacheRow.deleteOne(db, key: uuid)
            guard let row = try TimeSpanRow.filter(Column("uuid") == uuid).fetchOne(db) else {
                return .noop
            }
            if row.dirty { return .localWins }
            _ = try row.delete(db)
            return .deletedLocally
        }
    }

    // MARK: Applying fetched records — label sets

    func applyCloudLabelSet(_ remote: CloudLabelSet) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            if var row = try LabelSetRow.fetchOne(db, key: remote.uuid) {
                if row.dirty, (row.modifiedAt ?? .distantPast) > remote.modifiedAt {
                    return .localWins
                }
                if !row.dirty {
                    let localMembers = try Self.members(of: row.id, db)
                    let localQuick = try Self.quickMembers(of: row.id, db)
                    if row.name == remote.name
                        && (row.symbol ?? TagSet.markSymbol) == remote.symbolName
                        && row.position == remote.position
                        && localMembers == remote.labels
                        && localQuick == remote.quickLabels {
                        return .noop
                    }
                }
                // color/gradient are local-only and survive, as in the
                // self-hosted merge.
                row.name = remote.name
                row.symbol = remote.symbolName
                row.position = remote.position
                row.dirty = false
                try row.update(db)
                try LabelSetMemberRow.filter(Column("set_id") == row.id).deleteAll(db)
                try Self.insert(members: remote.labels, setId: row.id, db)
                try LabelSetQuickMemberRow.filter(Column("set_id") == row.id).deleteAll(db)
                try Self.insert(quickMembers: remote.quickLabels, setId: row.id, db)
                return .updated
            }
            if let tombstone = try SyncTombstoneRow
                .filter(Column("entity") == SyncEntity.labelSet.rawValue
                    && Column("target") == remote.uuid)
                .fetchOne(db) {
                guard remote.modifiedAt > tombstone.deletedAt else {
                    return .tombstoneWins
                }
                _ = try tombstone.delete(db)
                try Self.insertCleanCloudLabelSet(remote, db)
                return .resurrected
            }
            try Self.insertCleanCloudLabelSet(remote, db)
            return .inserted
        }
    }

    func applyCloudLabelSetDeletion(uuid: String) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            try Self.deleteTombstone(.labelSet, target: uuid, db)
            _ = try CloudRecordCacheRow.deleteOne(db, key: uuid)
            guard let row = try LabelSetRow.fetchOne(db, key: uuid) else {
                return .noop
            }
            if row.dirty { return .localWins }
            _ = try row.delete(db)   // members cascade
            return .deletedLocally
        }
    }

    // MARK: Applying fetched records — label definitions

    /// Merge one fetched definition: value LWW by key, plus record-name
    /// canonicalization. Two devices can mint different record names for
    /// the same key before either syncs; both sides converge by keeping the
    /// lexicographically smallest name — deterministic with no
    /// coordination — and deleting the loser. When the loser carried the
    /// newer content, the surviving row goes dirty so that content re-pushes
    /// onto the canonical record.
    func applyCloudDefinition(_ remote: CloudLabelDefinition, recordName: String) async throws
        -> CloudNaturalKeyMergeResult {
        try await dbQueue.write { db in
            let duplicate = try Self.canonicalizeCkName(.labelDefinition, localId: remote.key,
                                                        fetched: recordName, db)
            let fetchedNameSurvives = duplicate != recordName
            let local = try Row.fetchOne(
                db, sql: "SELECT color, dirty, modified_at FROM label_definition WHERE key = ?",
                arguments: [remote.key])
            guard let local else {
                try db.execute(
                    sql: "INSERT INTO label_definition (key, color, dirty) VALUES (?, ?, 0)",
                    arguments: [remote.key, remote.color])
                return CloudNaturalKeyMergeResult(outcome: .inserted,
                                                  duplicateRecordToDelete: duplicate)
            }
            let dirty: Bool = local["dirty"]
            let modifiedAt: Date? = local["modified_at"]
            if dirty, (modifiedAt ?? .distantPast) > remote.modifiedAt {
                return CloudNaturalKeyMergeResult(outcome: .localWins,
                                                  duplicateRecordToDelete: duplicate)
            }
            let changed = (local["color"] as String) != remote.color
            if fetchedNameSurvives || duplicate == nil {
                try db.execute(
                    sql: "UPDATE label_definition SET color = ?, dirty = 0 WHERE key = ?",
                    arguments: [remote.color, remote.key])
            } else {
                // The fetched record is the duplicate being deleted, but its
                // content won LWW: adopt it and go dirty, so it re-pushes
                // onto the canonical record.
                try db.execute(sql: """
                    UPDATE label_definition SET color = ?, dirty = 1, modified_at = ?
                    WHERE key = ?
                    """, arguments: [remote.color, remote.modifiedAt, remote.key])
            }
            return CloudNaturalKeyMergeResult(outcome: changed ? .updated : .noop,
                                              duplicateRecordToDelete: duplicate)
        }
    }

    /// A fetched definition deletion is (in practice) the echo of another
    /// device's duplicate-merge cleanup — the app never deletes definitions.
    /// If it names our mapped record, unmap and go dirty: if a canonical
    /// record exists its merge settles everything, and if not, the dirty
    /// row re-uploads under a fresh mint. Either way no local data is lost.
    func applyCloudDefinitionDeletion(recordName: String) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            _ = try CloudRecordCacheRow.deleteOne(db, key: recordName)
            guard let map = try Self.ckMap(recordName: recordName, db),
                  map.entity == SyncEntity.labelDefinition.rawValue else {
                return .noop
            }
            try Self.deleteCkMap(recordName: recordName, db)
            try db.execute(sql: "UPDATE label_definition SET dirty = 1 WHERE key = ?",
                           arguments: [map.localId])
            return .noop
        }
    }

    // MARK: Applying fetched records — value colors

    func applyCloudValueColor(_ remote: CloudValueColor, recordName: String) async throws
        -> CloudNaturalKeyMergeResult {
        try await dbQueue.write { db in
            let composite = ValueColorKey.join(remote.key, remote.value)
            let duplicate = try Self.canonicalizeCkName(.valueColor, localId: composite,
                                                        fetched: recordName, db)
            let fetchedNameSurvives = duplicate != recordName
            guard var local = try ValueColorRow
                .filter(Column("key") == remote.key && Column("value") == remote.value)
                .fetchOne(db) else {
                if let tombstone = try SyncTombstoneRow
                    .filter(Column("entity") == SyncEntity.valueColor.rawValue
                        && Column("target") == composite)
                    .fetchOne(db) {
                    guard remote.modifiedAt > tombstone.deletedAt else {
                        return CloudNaturalKeyMergeResult(outcome: .tombstoneWins,
                                                          duplicateRecordToDelete: duplicate)
                    }
                    _ = try tombstone.delete(db)
                    try ValueColorRow(key: remote.key, value: remote.value,
                                      color: remote.color, dirty: false,
                                      modifiedAt: nil).insert(db)
                    return CloudNaturalKeyMergeResult(outcome: .resurrected,
                                                      duplicateRecordToDelete: duplicate)
                }
                try ValueColorRow(key: remote.key, value: remote.value,
                                  color: remote.color, dirty: false,
                                  modifiedAt: nil).insert(db)
                return CloudNaturalKeyMergeResult(outcome: .inserted,
                                                  duplicateRecordToDelete: duplicate)
            }
            if local.dirty, (local.modifiedAt ?? .distantPast) > remote.modifiedAt {
                return CloudNaturalKeyMergeResult(outcome: .localWins,
                                                  duplicateRecordToDelete: duplicate)
            }
            let changed = local.color != remote.color
            local.color = remote.color
            if fetchedNameSurvives || duplicate == nil {
                local.dirty = false
            } else {
                local.dirty = true
                local.modifiedAt = remote.modifiedAt
            }
            try local.update(db)
            return CloudNaturalKeyMergeResult(outcome: changed ? .updated : .noop,
                                              duplicateRecordToDelete: duplicate)
        }
    }

    /// Value-color deletions are genuine (a cleared override) or duplicate-
    /// merge echoes; the same rule serves both — a dirty local override
    /// survives unmapped (it re-uploads under a fresh mint), a clean one
    /// mirrors the deletion.
    func applyCloudValueColorDeletion(recordName: String) async throws -> RemoteApplyOutcome {
        try await dbQueue.write { db in
            _ = try CloudRecordCacheRow.deleteOne(db, key: recordName)
            guard let map = try Self.ckMap(recordName: recordName, db),
                  map.entity == SyncEntity.valueColor.rawValue,
                  let (key, value) = ValueColorKey.split(map.localId) else {
                return .noop
            }
            try Self.deleteCkMap(recordName: recordName, db)
            try Self.deleteTombstone(.valueColor, target: map.localId, db)
            guard let row = try ValueColorRow
                .filter(Column("key") == key && Column("value") == value)
                .fetchOne(db) else {
                return .noop
            }
            if row.dirty { return .localWins }
            _ = try row.delete(db)
            return .deletedLocally
        }
    }

    // MARK: Shared helpers

    /// The CK sibling of `tombstoneIfMapped`: a local deletion leaves a
    /// tombstone only if the server knows the record (a cache row exists),
    /// and the cache row retires with it.
    static func tombstoneIfCloudKnown(entity: SyncEntity, recordName: String,
                                      _ db: Database) throws {
        guard try CloudRecordCacheRow.fetchOne(db, key: recordName) != nil else { return }
        try tombstone(entity: entity, target: recordName, at: Date(), db)
        _ = try CloudRecordCacheRow.deleteOne(db, key: recordName)
    }

    internal static func ckMap(_ entity: SyncEntity, ckLocalId: String,
                               _ db: Database) throws -> CloudRecordMapRow? {
        try CloudRecordMapRow
            .filter(Column("entity") == entity.rawValue && Column("local_id") == ckLocalId)
            .fetchOne(db)
    }

    internal static func ckMap(recordName: String, _ db: Database) throws -> CloudRecordMapRow? {
        try CloudRecordMapRow
            .filter(Column("record_name") == recordName)
            .fetchOne(db)
    }

    internal static func deleteCkMap(recordName: String, _ db: Database) throws {
        try CloudRecordMapRow
            .filter(Column("record_name") == recordName)
            .deleteAll(db)
    }

    /// The mapped record name for a natural-key entity, minting (and
    /// persisting) one on first use so retries stay stable.
    internal static func ckMapOrMint(_ entity: SyncEntity, localId: String,
                                     _ db: Database) throws -> String {
        if let map = try ckMap(entity, ckLocalId: localId, db) { return map.recordName }
        let name = UUID().uuidString
        try CloudRecordMapRow(entity: entity.rawValue, localId: localId,
                              recordName: name).insert(db)
        return name
    }

    /// Record-name canonicalization for one fetched natural-key record.
    /// Ensures the map points at the lexicographically smallest name seen
    /// for this key and returns the loser to delete server-side (nil when
    /// there is no duplicate).
    internal static func canonicalizeCkName(_ entity: SyncEntity, localId: String,
                                            fetched: String, _ db: Database) throws -> String? {
        guard let mapped = try ckMap(entity, ckLocalId: localId, db)?.recordName else {
            try CloudRecordMapRow(entity: entity.rawValue, localId: localId,
                                  recordName: fetched).insert(db)
            return nil
        }
        guard mapped != fetched else { return nil }
        if fetched < mapped {
            try CloudRecordMapRow
                .filter(Column("entity") == entity.rawValue && Column("local_id") == localId)
                .deleteAll(db)
            try CloudRecordMapRow(entity: entity.rawValue, localId: localId,
                                  recordName: fetched).insert(db)
            _ = try CloudRecordCacheRow.deleteOne(db, key: mapped)
            return mapped
        }
        _ = try CloudRecordCacheRow.deleteOne(db, key: fetched)
        return fetched
    }

    private static func insertCleanCloudSpan(_ remote: CloudSpan, _ db: Database) throws {
        var row = TimeSpanRow(id: nil, start: remote.start, end: remote.end,
                              note: remote.note, dirty: false, modifiedAt: nil,
                              uuid: remote.uuid)
        try row.insert(db)
        try insert(labels: remote.labels, spanId: row.id!, db)
    }

    private static func insertCleanCloudLabelSet(_ remote: CloudLabelSet, _ db: Database) throws {
        // color/gradient nil: the card look is local-only (see the
        // self-hosted merge's identical rule).
        try LabelSetRow(id: remote.uuid, name: remote.name, symbol: remote.symbolName,
                        color: nil, gradient: nil, position: remote.position,
                        dirty: false, modifiedAt: nil).insert(db)
        try insert(members: remote.labels, setId: remote.uuid, db)
        try insert(quickMembers: remote.quickLabels, setId: remote.uuid, db)
    }
}
