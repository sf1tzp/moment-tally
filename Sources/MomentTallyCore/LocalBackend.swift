import Foundation
import GRDB

// MARK: - Record rows
//
// The schema speaks the *label* vocabulary (#27) even while UI copy still says
// "tag" — a schema is the one place a rename would churn data, so it's born
// with the final words. `LabelDefinition` persists directly (it *is* its row);
// `TimeSpan` doesn't, because its labels live in a child table, so a pair of
// row types bridges it. Row types are internal (not private) so the sync
// store surface (SyncStore.swift) shares them.

extension LabelDefinition: FetchableRecord, PersistableRecord {
    package static var databaseTableName: String { "label_definition" }
}

/// One `time_span` row — the span without its labels. `dirty`/`modifiedAt`
/// are sync metadata (v3-sync): dirty means "not known to be on the sync
/// server" — rows are born dirty — and `modifiedAt` is the local wall-clock
/// time of the last local edit, this record's side of last-writer-wins.
struct TimeSpanRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "time_span"
    var id: Int64?
    var start: Date
    var end: Date?     // NULL = currently running
    var note: String
    var dirty = true
    var modifiedAt: Date?
    /// Client-minted identity (v7): the span's CloudKit record name. The
    /// rowid stays the local key; this is the identity that exists *before*
    /// any server roundtrip, unlike sync_map's server-assigned ids (#121).
    var uuid = UUID().uuidString

    enum CodingKeys: String, CodingKey {
        case id, start, end, note, dirty, modifiedAt = "modified_at", uuid
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One label on one span (`time_span_label`). Label order within a span is the
/// insertion order (rowid), so a span's labels render the way they were saved.
struct SpanLabelRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "time_span_label"
    var spanId: Int64
    var key: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case spanId = "span_id", key, value
    }
}

/// Maps an imported span back to its identity at the source (`span_origin`):
/// `origin` is the server it came from, `originId` its id there, `spanId` the
/// local row it landed in. This is what makes the importer idempotent — a
/// re-run finds the mapping and upserts — and it rehearses phase 6's
/// local-id ↔ server-id bookkeeping.
struct SpanOriginRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "span_origin"
    var origin: String
    var originId: Int64
    var spanId: Int64

    enum CodingKeys: String, CodingKey {
        case origin, originId = "origin_id", spanId = "span_id"
    }
}

/// A per-`key: value` color override (`value_color`) — first-class here,
/// unlike traggo where it's a client-side overlay on top of per-key colors.
/// `dirty`/`modifiedAt` as on `TimeSpanRow`.
struct ValueColorRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "value_color"
    var key: String
    var value: String
    var color: String
    var dirty = true
    var modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case key, value, color, dirty, modifiedAt = "modified_at"
    }
}

/// A saved tag set (`label_set`). `id` is the TagSet's UUID string so set
/// identity survives the round trip (quick-start matching, pane selection).
/// `dirty`/`modifiedAt` as on `TimeSpanRow`.
struct LabelSetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label_set"
    var id: String
    var name: String
    var symbol: String?
    /// Fallback launcher-card color ("#rrggbb"). Local-only: excluded from
    /// the dirty computation and the sync payload, and merges leave it alone.
    var color: String?
    /// Per-card gradient toggle (#226), nil = on. Local-only like `color`.
    var gradient: Bool? = nil
    var position: Int
    var dirty = true
    var modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, color, gradient, position, dirty,
             modifiedAt = "modified_at"
    }
}

/// One member tag of a set (`label_set_member`), ordered by `position`.
/// Key/value are stored as typed — un-normalised — matching what the legacy
/// UserDefaults JSON kept; normalisation stays at the `TagSet.labels` boundary.
struct LabelSetMemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label_set_member"
    var setId: String
    var position: Int
    var key: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case setId = "set_id", position, key, value
    }
}

/// One quick label of a set (`label_set_quick_member`, v5) — the one-click
/// refinements offered on hover (#61), shaped exactly like
/// `label_set_member`. A separate table rather than a kind column so the
/// existing member queries stay untouched; like members, quick rows carry
/// no sync metadata of their own — the owning set's `dirty`/`modified_at`
/// covers them (#92).
struct LabelSetQuickMemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label_set_quick_member"
    var setId: String
    var position: Int
    var key: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case setId = "set_id", position, key, value
    }
}

// MARK: - LocalBackend

/// The serverless `Backend`: a single SQLite file under Application Support,
/// via GRDB. Everything the traggo backend stores remotely lives here instead —
/// plus the things that were only ever local (tag sets, value colors), which
/// move out of UserDefaults and into the same file so local mode has one
/// backup-able artifact.
package final class LocalBackend: Backend {
    package struct Error: LocalizedError {
        package let message: String
        package var errorDescription: String? { message }

        package init(message: String) {
            self.message = message
        }
    }

    let dbQueue: DatabaseQueue
    /// Where the store lives on disk; nil for in-memory (tests).
    package let databaseURL: URL?
    /// Spans per page of `timeSpans(from:to:page:)`. Internal so tests can
    /// shrink it to exercise the page walk with few rows.
    var pageSize = 200

    /// The store has no login — the "account" is whoever owns the Mac.
    /// A stable id keeps `TimeSpan`/`User` shapes identical across backends.
    package static let localUser = User(
        id: 1,
        name: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(),
        admin: true)

    /// Opens (creating on first run) the default on-disk store.
    package convenience init(legacyDefaults: UserDefaults = .standard) throws {
        let url = try Self.defaultDatabaseURL()
        try self.init(DatabaseQueue(path: url.path), databaseURL: url,
                      legacyDefaults: legacyDefaults)
    }

    /// Designated initialiser; tests pass an in-memory `DatabaseQueue()`.
    package init(_ dbQueue: DatabaseQueue, databaseURL: URL? = nil,
         legacyDefaults: UserDefaults? = nil) throws {
        self.dbQueue = dbQueue
        self.databaseURL = databaseURL
        try Self.migrator(legacyDefaults: legacyDefaults).migrate(dbQueue)
    }

    /// `~/Library/Application Support/<bundle id>/momenttally.sqlite`. The
    /// SPM executable has no bundle identifier until the app is bundled, so
    /// fall back to the target name. Before settling on that path, adopt a
    /// pre-rename `primetime.sqlite` (#195) sitting in the same directory —
    /// scripts/migrate-container.sh renames the store when it moves the old
    /// container, but a store that arrived by any other route (manual copy,
    /// dev build) self-heals here. The -wal/-shm journal siblings move too:
    /// renaming the main file out from under its WAL would drop the
    /// uncheckpointed tail.
    package static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "MomentTally", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let fileManager = FileManager.default
        let url = directory.appendingPathComponent("momenttally.sqlite")
        if !fileManager.fileExists(atPath: url.path) {
            let legacy = directory.appendingPathComponent("primetime.sqlite")
            if fileManager.fileExists(atPath: legacy.path) {
                for suffix in ["", "-wal", "-shm"] {
                    let from = URL(fileURLWithPath: legacy.path + suffix)
                    guard fileManager.fileExists(atPath: from.path) else { continue }
                    try? fileManager.moveItem(
                        at: from, to: URL(fileURLWithPath: url.path + suffix))
                }
            }
        }
        return url
    }

    // MARK: Migrations

    /// The schema is applied through DatabaseMigrator from day one so phase 6
    /// can add sync metadata (server id, dirty flag, tombstone) as a plain
    /// later migration instead of a rebuild.
    // Internal (not private) so tests can stop at an intermediate migration
    // and prove the next one's backfill against realistic old-schema rows.
    static func migrator(legacyDefaults: UserDefaults?) -> DatabaseMigrator {
        // Read the legacy values up front: migration closures are @Sendable
        // and UserDefaults isn't, but the plain values it yields are.
        let legacyPresets = legacyDefaults?.data(forKey: "presets")
        let legacyColors = legacyDefaults?.dictionary(forKey: "valueColors") as? [String: String]
        let legacyQuickLabels = legacyDefaults?.data(forKey: "quickLabelsBySet")

        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-schema") { db in
            try db.create(table: "time_span") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime)                     // NULL = running
                t.column("note", .text).notNull().defaults(to: "")
            }
            try db.create(table: "time_span_label") { t in
                t.column("span_id", .integer).notNull().indexed()
                    .references("time_span", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
            }
            try db.create(table: "label_definition") { t in
                t.column("key", .text).primaryKey()
                t.column("color", .text).notNull()
            }
            try db.create(table: "value_color") { t in
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("color", .text).notNull()
                t.primaryKey(["key", "value"])
            }
            try db.create(table: "label_set") { t in
                t.column("id", .text).primaryKey()             // TagSet UUID
                t.column("name", .text).notNull()
                t.column("symbol", .text)                      // nil = default
                t.column("position", .integer).notNull()       // launcher order
            }
            try db.create(table: "label_set_member") { t in
                t.column("set_id", .text).notNull().indexed()
                    .references("label_set", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
            }
        }

        // One-time import of what used to be the app's only local persistence.
        // Running it as a migration gives the exactly-once semantics for free
        // (recorded in grdb_migrations, per database file). The legacy keys
        // are copied, not cleared, so nothing regresses if the old build runs
        // again. Inserts spell out the v1 columns because this migration runs
        // before v3-sync adds the sync metadata columns the record types now
        // carry; v3's defaults then mark these rows dirty like everything
        // else.
        migrator.registerMigration("v1-import-user-defaults") { db in
            // Fresh installs (no legacy presets) start with no label sets:
            // onboarding's walkthrough is where the user creates their first
            // ones, and pre-seeded samples would sit next to those picks.
            let sets: [TagSet]
            if let data = legacyPresets,
               let decoded = try? JSONDecoder().decode([TagSet].self, from: data) {
                sets = decoded
            } else {
                sets = []
            }
            for (position, set) in sets.enumerated() {
                try db.execute(
                    sql: "INSERT INTO label_set (id, name, symbol, position) VALUES (?, ?, ?, ?)",
                    arguments: [set.id.uuidString, set.name, set.symbolName, position])
                for (memberPosition, tag) in set.tags.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO label_set_member (set_id, position, key, value) VALUES (?, ?, ?, ?)",
                        arguments: [set.id.uuidString, memberPosition, tag.key, tag.value])
                }
            }

            for (composite, color) in legacyColors ?? [:] {
                guard let (key, value) = ValueColorKey.split(composite) else { continue }
                try db.execute(
                    sql: "INSERT INTO value_color (key, value, color) VALUES (?, ?, ?)",
                    arguments: [key, value, color])
            }
        }

        // Origin-id mapping for the traggo importer (#30). A separate table
        // rather than a column on time_span: most spans are born local and
        // never have an origin, and phase 6's sync metadata (server id, dirty
        // flag, tombstone) can grow out of the same shape later.
        migrator.registerMigration("v2-span-origin") { db in
            try db.create(table: "span_origin") { t in
                t.column("origin", .text).notNull()        // source server URL
                t.column("origin_id", .integer).notNull()  // the span's id there
                t.column("span_id", .integer).notNull().unique()
                    .references("time_span", onDelete: .cascade)
                t.primaryKey(["origin", "origin_id"])
            }
        }

        // Sync metadata (#33) — the migration the v1 schema left room for.
        // Every syncable table gets a dirty flag ("not known to be on the
        // sync server"; existing rows are born dirty because nothing that
        // predates this migration was ever pushed) and modified_at, the
        // local wall-clock time of the last local edit — this store's side
        // of last-writer-wins. Identity and deletions live in side tables,
        // the span_origin idea graduated: sync_map pairs a local id with
        // its id on the connected server, sync_tombstone remembers local
        // deletions until they are pushed, and sync_server is the single
        // row that *is* the connection (URL, account, pull checkpoint) —
        // connected-ness is a property of the store, not a separate
        // backend. The device token lives in the Keychain, never here.
        migrator.registerMigration("v3-sync") { db in
            for table in ["time_span", "label_definition", "value_color", "label_set"] {
                try db.alter(table: table) { t in
                    t.add(column: "dirty", .boolean).notNull().defaults(to: true)
                    t.add(column: "modified_at", .datetime)
                }
            }
            try db.create(table: "sync_server") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("url", .text).notNull()
                t.column("user_id", .integer).notNull()
                t.column("user_name", .text).notNull()
                // False after a disconnect: syncing stops but mappings and
                // clean/dirty state survive, so reconnecting to the same
                // server resumes instead of duplicating everything.
                t.column("active", .boolean).notNull().defaults(to: true)
                // The timespan delta-feed checkpoint: the last pulled
                // record's (updatedAt, id) — see docs/api-v1.md "Sync".
                t.column("checkpoint", .datetime)
                t.column("checkpoint_after_id", .integer).notNull().defaults(to: 0)
                // Preference sync metadata rides here because the two
                // preference *values* live in UserDefaults, not this file.
                t.column("prefs_dirty", .boolean).notNull().defaults(to: true)
                t.column("prefs_modified_at", .datetime)
                t.column("last_synced_at", .datetime)
            }
            try db.create(table: "sync_map") { t in
                t.column("entity", .text).notNull()    // SyncEntity raw value
                t.column("local_id", .text).notNull()  // span rowid / set UUID
                t.column("server_id", .integer).notNull()
                t.primaryKey(["entity", "local_id"])
                t.uniqueKey(["entity", "server_id"])
            }
            try db.create(table: "sync_tombstone") { t in
                t.column("entity", .text).notNull()
                // The server-side identity to delete: a server id for spans
                // and label sets, a key␟value composite for value colors.
                t.column("target", .text).notNull()
                t.column("deleted_at", .datetime).notNull()
                t.primaryKey(["entity", "target"])
            }
        }

        // Fallback launcher-card color for sets with no labels. Local-only —
        // deliberately not part of the sync payload, so it neither
        // participates in the dirty flag nor rides `LabelSetPush`.
        migrator.registerMigration("v4-label-set-color") { db in
            try db.alter(table: "label_set") { t in
                t.add(column: "color", .text)              // nil = accent
            }
        }

        // Quick labels (#92) move from the AppModel's UserDefaults JSON blob
        // into the store, next to label_set_member, so the label-set sync
        // machinery covers them. The import follows the v1 precedent —
        // copied, not cleared, so nothing regresses if an old build runs
        // again. Migrated quick labels have never been pushed, so their
        // owning sets go dirty; blob entries for sets that no longer exist
        // (deletions left them lingering harmlessly) are dropped.
        migrator.registerMigration("v5-quick-labels") { db in
            try db.create(table: "label_set_quick_member") { t in
                t.column("set_id", .text).notNull().indexed()
                    .references("label_set", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
            }
            guard let data = legacyQuickLabels,
                  let decoded = try? JSONDecoder().decode([String: [TagRow]].self, from: data)
            else { return }
            let setIds = Set(try String.fetchAll(db, sql: "SELECT id FROM label_set"))
            let now = Date()
            for (setId, rows) in decoded where setIds.contains(setId) && !rows.isEmpty {
                for (position, row) in rows.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO label_set_quick_member (set_id, position, key, value) VALUES (?, ?, ?, ?)",
                        arguments: [setId, position, row.key, row.value])
                }
                try db.execute(
                    sql: "UPDATE label_set SET dirty = 1, modified_at = ? WHERE id = ?",
                    arguments: [now, setId])
            }
        }

        // Per-card gradient toggle (#226), replacing the global launcher
        // preference (AppModel migrates a stored false into the cards once).
        // Local-only like `color`: not in the dirty computation or the sync
        // payload, and merges leave it alone.
        migrator.registerMigration("v6-label-set-gradient") { db in
            try db.alter(table: "label_set") { t in
                t.add(column: "gradient", .boolean)        // nil = gradient on
            }
        }

        // CloudKit identity groundwork (#121, #159). Spans get client-minted
        // UUIDs: CloudKit record names need an identity that exists before
        // any server roundtrip, unlike sync_map's server-assigned ids. The
        // column stays nullable in SQL (SQLite can't retro-fit NOT NULL);
        // the backfill plus the record type's insert-time default keep it
        // populated, and the unique index enforces what matters. sync_server
        // learns which transport it describes plus a slot for CKSyncEngine's
        // opaque state serialization, and ck_record_map holds minted record
        // names for natural-key entities — record names travel unencrypted,
        // so a definition's user-typed key can never be one.
        migrator.registerMigration("v7-cloudkit-identity") { db in
            try db.alter(table: "time_span") { t in
                t.add(column: "uuid", .text)
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM time_span") {
                try db.execute(sql: "UPDATE time_span SET uuid = ? WHERE id = ?",
                               arguments: [UUID().uuidString, id])
            }
            try db.create(indexOn: "time_span", columns: ["uuid"], options: .unique)
            try db.alter(table: "sync_server") { t in
                t.add(column: "transport", .text).notNull()
                    .defaults(to: SyncTransport.server.rawValue)
                t.add(column: "ck_state", .blob)
            }
            try db.create(table: "ck_record_map") { t in
                t.column("entity", .text).notNull()
                t.column("local_id", .text).notNull()
                t.column("record_name", .text).notNull()
                t.primaryKey(["entity", "local_id"])
                t.uniqueKey(["entity", "record_name"])
            }
        }

        // The CloudKit record cache (#121): the last server copy seen per
        // record, as a full NSKeyedArchiver archive. The server change tag
        // rides inside, and a save must be based on the server's current
        // tag or it's a conflict — this is what lets a relaunched app
        // update records without a fetch-before-every-save. (A full archive
        // rather than `encodeSystemFields`: system-fields-only archiving
        // strips everything the CI fake models its change tag with, and the
        // payload duplication is a few hundred bytes per record.) Presence
        // in this table is also the transport's "the server knows this
        // record" marker (the CK sibling of a sync_map row), which is what
        // decides whether a local deletion leaves a tombstone. Losing a row
        // here is safe: the next save goes out as a fresh instance,
        // conflicts once, and heals from the server copy in the failure.
        migrator.registerMigration("v8-cloudkit-record-cache") { db in
            try db.create(table: "ck_record_cache") { t in
                t.column("record_name", .text).primaryKey()
                t.column("archived_record", .blob).notNull()
            }
        }

        return migrator
    }

    // MARK: Backend — session

    package func currentUser() async throws -> User? { Self.localUser }

    // MARK: Backend — label definitions

    package func labelDefinitions() async throws -> [LabelDefinition] {
        try await dbQueue.read { db in
            try LabelDefinition.order(Column("key")).fetchAll(db)
        }
    }

    package func createLabelDefinition(key: String, color: String) async throws {
        try await dbQueue.write { db in
            // A duplicate insert throws (unique key), matching traggo's
            // create-vs-update split that callers already navigate. The
            // insert only names the domain columns, so `dirty` takes its
            // born-dirty default; stamp the local edit time separately.
            try LabelDefinition(key: key, color: color).insert(db)
            try db.execute(sql: "UPDATE label_definition SET modified_at = ? WHERE key = ?",
                           arguments: [Date(), key])
        }
    }

    package func updateLabelDefinition(key: String, color: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE label_definition SET color = ?, dirty = 1, modified_at = ? WHERE key = ?",
                           arguments: [color, Date(), key])
            guard db.changesCount > 0 else {
                throw Error(message: "No such label key: \(key)")
            }
        }
    }

    // MARK: Backend — timespans

    package func timers() async throws -> [TimeSpan] {
        try await dbQueue.read { db in
            let rows = try TimeSpanRow
                .filter(Column("end") == nil)
                .order(Column("start"))
                .fetchAll(db)
            return try Self.spans(for: rows, db)
        }
    }

    package func startTimeSpan(start: Date, labels: [SpanLabel], note: String) async throws -> TimeSpan {
        try await dbQueue.write { db in
            var row = TimeSpanRow(id: nil, start: start, end: nil, note: note,
                                  dirty: true, modifiedAt: Date())
            try row.insert(db)
            try Self.insert(labels: labels, spanId: row.id!, db)
            return try Self.span(for: row, db)
        }
    }

    package func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> TimeSpan {
        try await dbQueue.write { db in
            guard var row = try TimeSpanRow.fetchOne(db, key: Int64(id)) else {
                throw Error(message: "No such timespan: \(id)")
            }
            row.start = start
            row.end = end
            row.note = note
            row.dirty = true
            row.modifiedAt = Date()
            try row.update(db)
            // Labels are replaced wholesale — the protocol's "every field is
            // written" contract — which also renumbers their display order.
            try SpanLabelRow.filter(Column("span_id") == Int64(id)).deleteAll(db)
            try Self.insert(labels: labels, spanId: Int64(id), db)
            return try Self.span(for: row, db)
        }
    }

    package func stopTimeSpan(id: Int, end: Date) async throws -> TimeSpan {
        try await dbQueue.write { db in
            guard var row = try TimeSpanRow.fetchOne(db, key: Int64(id)) else {
                throw Error(message: "No such timespan: \(id)")
            }
            row.end = end
            row.dirty = true
            row.modifiedAt = Date()
            try row.update(db)
            return try Self.span(for: row, db)
        }
    }

    package func removeTimeSpan(id: Int) async throws {
        try await dbQueue.write { db in
            guard let row = try TimeSpanRow.fetchOne(db, key: Int64(id)) else {
                throw Error(message: "No such timespan: \(id)")
            }
            // If the span is known to the sync server, remember the deletion
            // until it's pushed; the mapping row itself is retired with it.
            // Each transport has its own "known to the server" marker: a
            // sync_map row (self-hosted) or a ck_record_cache row (CloudKit).
            try Self.tombstoneIfMapped(entity: .span, localId: String(id), db)
            try Self.tombstoneIfCloudKnown(entity: .span, recordName: row.uuid, db)
            _ = try TimeSpanRow.deleteOne(db, key: Int64(id))
            // time_span_label rows follow via ON DELETE CASCADE.
        }
    }

    /// Keyset pagination over finished spans overlapping [from, to], newest
    /// first: the token carries the last row's (start, id) and the next page
    /// resumes strictly after it. Unlike offsets, this stays stable when spans
    /// are inserted or deleted mid-walk — the Tag Review scan mutates nothing,
    /// but Approve Changes could interleave with a running History load.
    package func timeSpans(from: Date, to: Date, page: PageToken?) async throws -> TimeSpanPage {
        let cursor = page.flatMap(LocalCursor.init)
        let pageSize = pageSize
        return try await dbQueue.read { db in
            var request = TimeSpanRow
                .filter(Column("end") != nil)
                .filter(Column("start") <= to && Column("end") >= from)
            if let cursor {
                request = request.filter(
                    Column("start") < cursor.start
                        || (Column("start") == cursor.start && Column("id") < cursor.id))
            }
            // Fetch one extra row purely to learn whether more exist, so the
            // last full page doesn't mint a token to an empty page.
            let rows = try request
                .order(Column("start").desc, Column("id").desc)
                .limit(pageSize + 1)
                .fetchAll(db)
            let pageRows = Array(rows.prefix(pageSize))
            let next: PageToken? = rows.count > pageSize
                ? LocalCursor(start: pageRows.last!.start, id: pageRows.last!.id!).pageToken
                : nil
            return TimeSpanPage(timeSpans: try Self.spans(for: pageRows, db),
                                nextPage: next)
        }
    }

    // MARK: Tag sets + value colors (local-only surface, not part of Backend)
    //
    // Synchronous by design: AppModel persists these from didSet observers on
    // the main actor, exactly like the UserDefaults writes they replace, and
    // the tables are a few dozen rows at most.

    package func loadTagSets() throws -> [TagSet] {
        try dbQueue.read { db in
            let sets = try LabelSetRow.order(Column("position")).fetchAll(db)
            let members = try LabelSetMemberRow.order(Column("position")).fetchAll(db)
            let bySet = Dictionary(grouping: members, by: \.setId)
            return sets.map { row in
                TagSet(id: UUID(uuidString: row.id) ?? UUID(),
                       name: row.name,
                       tags: (bySet[row.id] ?? []).map { TagRow(key: $0.key, value: $0.value) },
                       symbolName: row.symbol,
                       colorHex: row.color,
                       gradient: row.gradient)
            }
        }
    }

    /// Snapshot save with per-row diffing: the caller still hands over the
    /// whole list (the semantics the UserDefaults JSON blob had), but rows
    /// are updated in place so sync metadata survives — only sets that
    /// actually changed go dirty, and a set that disappears leaves a
    /// tombstone if the sync server knows it. Members are rewritten
    /// wholesale (they carry no metadata of their own).
    package func saveTagSets(_ sets: [TagSet]) throws {
        try dbQueue.write { db in
            let now = Date()
            let existing = try LabelSetRow.fetchAll(db)
            let members = try LabelSetMemberRow.order(Column("position")).fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let membersBySet = Dictionary(grouping: members, by: \.setId)
            var kept = Set<String>()

            for (position, set) in sets.enumerated() {
                let id = set.id.uuidString
                kept.insert(id)
                let newMembers = set.tags.enumerated().map { index, tag in
                    LabelSetMemberRow(setId: id, position: index,
                                      key: tag.key, value: tag.value)
                }
                if var row = byId[id] {
                    let oldMembers = membersBySet[id] ?? []
                    // `color` and `gradient` are deliberately absent: they
                    // aren't synced, so a cosmetic change alone must not
                    // dirty the row (that would push an otherwise-unchanged
                    // set). The update below still persists them.
                    let changed = row.name != set.name
                        || row.symbol != set.symbolName
                        || row.position != position
                        || oldMembers.count != newMembers.count
                        || !zip(oldMembers, newMembers).allSatisfy {
                            $0.key == $1.key && $0.value == $1.value
                        }
                    row.name = set.name
                    row.symbol = set.symbolName
                    row.color = set.colorHex
                    row.gradient = set.gradient
                    row.position = position
                    if changed {
                        row.dirty = true
                        row.modifiedAt = now
                    }
                    try row.update(db)
                } else {
                    try LabelSetRow(id: id, name: set.name, symbol: set.symbolName,
                                    color: set.colorHex, gradient: set.gradient,
                                    position: position,
                                    dirty: true, modifiedAt: now).insert(db)
                }
                try LabelSetMemberRow.filter(Column("set_id") == id).deleteAll(db)
                for member in newMembers {
                    try member.insert(db)
                }
            }

            for row in existing where !kept.contains(row.id) {
                try Self.tombstoneIfMapped(entity: .labelSet, localId: row.id, db)
                try Self.tombstoneIfCloudKnown(entity: .labelSet, recordName: row.id, db)
                _ = try row.delete(db)   // members cascade
            }
        }
    }

    /// Quick labels per set, in AppModel's dictionary form (set UUID string
    /// → ordered rows), so the in-memory representation matches what the
    /// UserDefaults blob held.
    package func loadQuickLabels() throws -> [String: [TagRow]] {
        try dbQueue.read { db in
            let rows = try LabelSetQuickMemberRow.order(Column("position")).fetchAll(db)
            var quickLabels: [String: [TagRow]] = [:]
            for row in rows {
                quickLabels[row.setId, default: []].append(TagRow(key: row.key, value: row.value))
            }
            return quickLabels
        }
    }

    /// Snapshot save with per-set diffing, like `saveTagSets`: quick labels
    /// ride the owning set's sync record, so a set whose quick list changed
    /// goes dirty (and pushes) while untouched sets keep their sync state.
    /// Entries for set ids not in the store are ignored — the in-memory
    /// dictionary keeps entries for deleted sets, harmlessly.
    package func saveQuickLabels(_ quickLabels: [String: [TagRow]]) throws {
        try dbQueue.write { db in
            let now = Date()
            let setIds = try String.fetchAll(db, sql: "SELECT id FROM label_set")
            let existing = try LabelSetQuickMemberRow.order(Column("position")).fetchAll(db)
            let bySet = Dictionary(grouping: existing, by: \.setId)
            for setId in setIds {
                let old = bySet[setId] ?? []
                let new = quickLabels[setId] ?? []
                let changed = old.count != new.count
                    || !zip(old, new).allSatisfy { $0.key == $1.key && $0.value == $1.value }
                guard changed else { continue }
                try LabelSetQuickMemberRow.filter(Column("set_id") == setId).deleteAll(db)
                for (position, row) in new.enumerated() {
                    try LabelSetQuickMemberRow(setId: setId, position: position,
                                               key: row.key, value: row.value).insert(db)
                }
                try db.execute(
                    sql: "UPDATE label_set SET dirty = 1, modified_at = ? WHERE id = ?",
                    arguments: [now, setId])
            }
        }
    }

    /// In AppModel's composite-key dictionary form (`key␟value` → hex), so the
    /// in-memory representation is identical whichever store backs it.
    package func loadValueColors() throws -> [String: String] {
        try dbQueue.read { db in
            var colors: [String: String] = [:]
            for row in try ValueColorRow.fetchAll(db) {
                colors[ValueColorKey.join(row.key, row.value)] = row.color
            }
            return colors
        }
    }

    /// Snapshot save with per-row diffing, like `saveTagSets`: unchanged
    /// overrides keep their sync metadata, removed ones leave a tombstone
    /// when a sync server is connected (value colors have no id mapping —
    /// their key␟value pair *is* the identity on both sides).
    package func saveValueColors(_ colors: [String: String]) throws {
        try dbQueue.write { db in
            let now = Date()
            let existing = try ValueColorRow.fetchAll(db)
            let byComposite = Dictionary(uniqueKeysWithValues: existing.map {
                (ValueColorKey.join($0.key, $0.value), $0)
            })
            var kept = Set<String>()

            for (composite, color) in colors {
                guard let (key, value) = ValueColorKey.split(composite) else { continue }
                kept.insert(composite)
                if var row = byComposite[composite] {
                    if row.color != color {
                        row.color = color
                        row.dirty = true
                        row.modifiedAt = now
                        try row.update(db)
                    }
                } else {
                    try ValueColorRow(key: key, value: value, color: color,
                                      dirty: true, modifiedAt: now).insert(db)
                }
            }

            let connected = try Self.hasSyncServer(db)
            for row in existing where !kept.contains(ValueColorKey.join(row.key, row.value)) {
                if connected {
                    try Self.tombstone(entity: .valueColor,
                                       target: ValueColorKey.join(row.key, row.value),
                                       at: now, db)
                }
                _ = try row.delete(db)
            }
        }
    }

    // MARK: Demo seeding (see DemoMode.swift)
    //
    // Synchronous like the tag-set/value-color surface, and for the same
    // reason: the seeder runs inside the (main-actor) backend activation.
    // These live here rather than with the seeder because they need the
    // file-private row types.

    /// Replace every label definition in one transaction.
    func replaceLabelDefinitions(_ definitions: [LabelDefinition]) throws {
        try dbQueue.write { db in
            try LabelDefinition.deleteAll(db)
            for definition in definitions {
                try definition.insert(db)
            }
        }
    }

    /// Replace every timespan (labels cascade) with the given seed rows, in
    /// one transaction.
    func replaceTimeSpans(with spans: [DemoSeed.SeedSpan]) throws {
        try dbQueue.write { db in
            try TimeSpanRow.deleteAll(db)
            for span in spans {
                var row = TimeSpanRow(id: nil, start: span.start, end: span.end,
                                      note: span.note)
                try row.insert(db)
                try Self.insert(labels: span.labels, spanId: row.id!, db)
            }
        }
    }

    // MARK: Import (origin-mapped upserts, used by HistoryImporter)

    /// Upsert label definitions by key. The imported color wins over a local
    /// one: the source has been the store of record for these keys, and the
    /// colors already local are mostly the auto-created default blue — see
    /// the importer's doc comment for the full policy rationale.
    package func importLabelDefinitions(_ definitions: [LabelDefinition]) async throws
        -> (created: Int, recolored: Int) {
        try await dbQueue.write { db in
            var created = 0, recolored = 0
            for definition in definitions {
                if let existing = try LabelDefinition.fetchOne(db, key: definition.key) {
                    if existing.color != definition.color {
                        try definition.update(db)
                        try db.execute(
                            sql: "UPDATE label_definition SET dirty = 1, modified_at = ? WHERE key = ?",
                            arguments: [Date(), definition.key])
                        recolored += 1
                    }
                } else {
                    try definition.insert(db)
                    try db.execute(
                        sql: "UPDATE label_definition SET modified_at = ? WHERE key = ?",
                        arguments: [Date(), definition.key])
                    created += 1
                }
            }
            return (created, recolored)
        }
    }

    /// Upsert one batch of spans from `origin`, in a single transaction. Here
    /// `TimeSpan.id` is the span's id *at the source*, not a local rowid: a
    /// `span_origin` mapping decides whether the span updates the local row a
    /// previous run created or inserts (and maps) a fresh one. A nil `end`
    /// imports the span as still running.
    package func importSpans(_ spans: [TimeSpan], origin: String) async throws
        -> (inserted: Int, updated: Int) {
        try await dbQueue.write { db in
            var inserted = 0, updated = 0
            for span in spans {
                let mapping = try SpanOriginRow
                    .filter(Column("origin") == origin
                        && Column("origin_id") == Int64(span.id))
                    .fetchOne(db)
                if let mapping,
                   var row = try TimeSpanRow.fetchOne(db, key: mapping.spanId) {
                    row.start = span.start
                    row.end = span.end
                    row.note = span.note
                    // Imported data is local data: it still has to reach the
                    // sync server, so imports dirty the row like any edit.
                    row.dirty = true
                    row.modifiedAt = Date()
                    try row.update(db)
                    try SpanLabelRow.filter(Column("span_id") == mapping.spanId).deleteAll(db)
                    try Self.insert(labels: span.labels, spanId: mapping.spanId, db)
                    updated += 1
                } else {
                    var row = TimeSpanRow(id: nil, start: span.start,
                                          end: span.end, note: span.note,
                                          dirty: true, modifiedAt: Date())
                    try row.insert(db)
                    try Self.insert(labels: span.labels, spanId: row.id!, db)
                    try SpanOriginRow(origin: origin, originId: Int64(span.id),
                                      spanId: row.id!).insert(db)
                    inserted += 1
                }
            }
            return (inserted, updated)
        }
    }

    // MARK: Shared row plumbing

    static func insert(labels: [SpanLabel], spanId: Int64, _ db: Database) throws {
        for label in labels {
            try SpanLabelRow(spanId: spanId, key: label.key, value: label.value).insert(db)
        }
    }

    static func span(for row: TimeSpanRow, _ db: Database) throws -> TimeSpan {
        try spans(for: [row], db).first!
    }

    /// Assemble domain `TimeSpan`s: one labels query for the whole page rather
    /// than one per span.
    static func spans(for rows: [TimeSpanRow], _ db: Database) throws -> [TimeSpan] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.compactMap(\.id)
        let labelRows = try SpanLabelRow
            .filter(ids.contains(Column("span_id")))
            .order(Column("rowid"))
            .fetchAll(db)
        var labels: [Int64: [SpanLabel]] = [:]
        for row in labelRows {
            labels[row.spanId, default: []].append(SpanLabel(key: row.key, value: row.value))
        }
        return rows.map { row in
            TimeSpan(id: Int(row.id!), start: row.start, end: row.end,
                     note: row.note, labels: labels[row.id!] ?? [])
        }
    }
}

// MARK: - Paging token

/// The local backend's paging state, riding opaquely in `PageToken` the same
/// way traggo's cursor does: JSON, decodable only by the backend that minted
/// it. `start` round-trips exactly because both sides carry GRDB's stored
/// (millisecond) precision.
private struct LocalCursor: Codable {
    let start: Date
    let id: Int64

    var pageToken: PageToken? {
        guard let data = try? JSONEncoder().encode(self),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return PageToken(rawValue: raw)
    }

    /// Nil for tokens this backend didn't mint; callers only hand back our own.
    init?(_ token: PageToken) {
        guard let data = token.rawValue.data(using: .utf8),
              let cursor = try? JSONDecoder().decode(LocalCursor.self, from: data) else { return nil }
        self = cursor
    }

    init(start: Date, id: Int64) {
        self.start = start
        self.id = id
    }
}
