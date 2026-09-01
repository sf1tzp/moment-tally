#if canImport(CloudKit)
import CloudKit
#endif
import Foundation

// MARK: - CloudKit schema (#121)
//
// One custom zone in the private database. Two rules shape everything here:
//
// • **Nothing user-authored leaves encryptedValues.** Record names, record
//   types, and plain fields travel unencrypted through CloudKit (Apple can
//   read them; some surface in dashboards). That rules out natural-key
//   record names — a label definition's record name would literally be the
//   user's label text — so definitions and value colors get minted UUID
//   names (mapped in ck_record_map), while spans and label sets reuse the
//   client UUIDs they already carry. Deterministic natural-key names would
//   have converged across devices for free; instead the transport merges
//   duplicates by natural key on fetch, which the LWW merge layer
//   (SyncStore.swift) already knows how to do.
//
// • **The production schema is promote-only.** Once a record type's fields
//   are promoted to production they can never be removed or retyped, so
//   every record carries a version field from the first shipped build, and
//   decoding refuses records written by a *newer* build rather than
//   guessing at fields it doesn't know.

package enum CloudKitSchema {
    /// Shared by the Mac and iOS apps — with universal purchase both use the
    /// same bundle id, but the container id is its own decision and is
    /// forever once an entitlement ships (#121 "decide before starting").
    package static let containerId = "iCloud.com.streetfortress.MomentTally"

    /// The one custom zone. A custom zone (not the default zone) is what
    /// buys atomic batch saves, change tokens, and CKSyncEngine support.
    package static let zoneName = "MomentTally"

    #if canImport(CloudKit)
    package static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
    #endif

    package enum RecordType {
        package static let span = "Span"
        package static let labelDefinition = "LabelDefinition"
        package static let valueColor = "ValueColor"
        package static let labelSet = "LabelSet"
        package static let preferences = "Preferences"
    }

    /// The preferences singleton's fixed record name — a constant, so it is
    /// allowed outside encryptedValues.
    package static let preferencesRecordName = "preferences"

    /// The record format version, the only plain (unencrypted) field on any
    /// record. Bump when a change is more than adding an optional field.
    package static let currentRecordVersion = 1
    static let versionKey = "v"
}

// MARK: - Record payloads
//
// What one CloudKit record holds, as plain values — the CK-transport
// siblings of the Remote* shapes in SyncServerAPI.swift. The differences
// are exactly the transport differences: identity is a client-minted UUID
// string (or the natural key itself) instead of a server-assigned Int, and
// `modifiedAt` is the *writing device's* edit clock rather than a server
// receipt time — with no server minting timestamps, LWW compares device
// clocks, which the existing merge semantics already tolerate (ties go to
// the incumbent remote copy).

package struct CloudSpan: Equatable {
    package let uuid: String
    package let start: Date
    package let end: Date?         // nil == running
    package let note: String
    /// Ordered — and the order is contractual on this transport: labels ride
    /// as one encrypted array payload, not child rows, so a span's labels
    /// can never come back shuffled (#159).
    package let labels: [SpanLabel]
    package let modifiedAt: Date

    package init(uuid: String, start: Date, end: Date?, note: String,
                 labels: [SpanLabel], modifiedAt: Date) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.note = note
        self.labels = labels
        self.modifiedAt = modifiedAt
    }
}

package struct CloudLabelDefinition: Equatable {
    package let key: String
    package let color: String
    package let modifiedAt: Date

    package init(key: String, color: String, modifiedAt: Date) {
        self.key = key
        self.color = color
        self.modifiedAt = modifiedAt
    }
}

package struct CloudValueColor: Equatable {
    package let key: String
    package let value: String
    package let color: String
    package let modifiedAt: Date

    package init(key: String, value: String, color: String, modifiedAt: Date) {
        self.key = key
        self.value = value
        self.color = color
        self.modifiedAt = modifiedAt
    }
}

package struct CloudLabelSet: Equatable {
    package let uuid: String
    package let name: String
    package let symbolName: String
    package let labels: [SpanLabel]
    package let quickLabels: [SpanLabel]
    /// Launcher position, carried as a field: CloudKit has no server-side
    /// array to index into, unlike the v1 API's `labelSets()` order.
    package let position: Int
    package let modifiedAt: Date

    package init(uuid: String, name: String, symbolName: String,
                 labels: [SpanLabel], quickLabels: [SpanLabel],
                 position: Int, modifiedAt: Date) {
        self.uuid = uuid
        self.name = name
        self.symbolName = symbolName
        self.labels = labels
        self.quickLabels = quickLabels
        self.position = position
        self.modifiedAt = modifiedAt
    }
}

package struct CloudPreferences: Equatable {
    package let colorByValue: Bool
    package let menuLabelSetLimit: Int
    package let modifiedAt: Date

    package init(colorByValue: Bool, menuLabelSetLimit: Int, modifiedAt: Date) {
        self.colorByValue = colorByValue
        self.menuLabelSetLimit = menuLabelSetLimit
        self.modifiedAt = modifiedAt
    }
}

// MARK: - The codec

// Apple-only from here down (#85): the payload structs above are plain
// values the CK-keyed store surface uses on every platform; the codec is
// the CKRecord half.
#if canImport(CloudKit)

/// Payload ↔ CKRecord, both directions, no CloudKit I/O — records are plain
/// objects until an operation ships them, which is what lets the whole codec
/// run under test with no container. Encoding always goes through `apply` so
/// the transport can re-encode onto a record *fetched from the server*: a
/// CKRecord carries an opaque change tag, and saving a fresh instance where
/// the server already holds one is a conflict, not an update.
package enum CloudKitRecordCodec {

    package enum DecodeError: Error, Equatable {
        /// Written by a newer app build than this one — surface "update this
        /// device", don't guess (the schema is promote-only; see above).
        case newerRecordVersion(Int)
        case wrongRecordType(expected: String, got: String)
        case missingField(String)
    }

    // MARK: Spans

    package static func record(for span: CloudSpan) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSchema.RecordType.span,
            recordID: CKRecord.ID(recordName: span.uuid,
                                  zoneID: CloudKitSchema.zoneID))
        apply(span, to: record)
        return record
    }

    package static func apply(_ span: CloudSpan, to record: CKRecord) {
        stampVersion(record)
        let values = record.encryptedValues
        values["start"] = span.start
        values["end"] = span.end               // nil clears a stale value
        values["note"] = span.note
        values["labels"] = encode(labels: span.labels)
        values["modifiedAt"] = span.modifiedAt
    }

    package static func span(from record: CKRecord) throws -> CloudSpan {
        try validate(record, as: CloudKitSchema.RecordType.span)
        let values = record.encryptedValues
        return CloudSpan(
            uuid: record.recordID.recordName,
            start: try require(values["start"] as? Date, "start"),
            end: values["end"] as? Date,
            note: try require(values["note"] as? String, "note"),
            labels: try decodeLabels(try require(values["labels"] as? Data, "labels")),
            modifiedAt: try require(values["modifiedAt"] as? Date, "modifiedAt"))
    }

    // MARK: Label definitions

    package static func record(for definition: CloudLabelDefinition,
                               recordName: String) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSchema.RecordType.labelDefinition,
            recordID: CKRecord.ID(recordName: recordName,
                                  zoneID: CloudKitSchema.zoneID))
        apply(definition, to: record)
        return record
    }

    package static func apply(_ definition: CloudLabelDefinition, to record: CKRecord) {
        stampVersion(record)
        let values = record.encryptedValues
        values["key"] = definition.key
        values["color"] = definition.color
        values["modifiedAt"] = definition.modifiedAt
    }

    package static func labelDefinition(from record: CKRecord) throws -> CloudLabelDefinition {
        try validate(record, as: CloudKitSchema.RecordType.labelDefinition)
        let values = record.encryptedValues
        return CloudLabelDefinition(
            key: try require(values["key"] as? String, "key"),
            color: try require(values["color"] as? String, "color"),
            modifiedAt: try require(values["modifiedAt"] as? Date, "modifiedAt"))
    }

    // MARK: Value colors

    package static func record(for valueColor: CloudValueColor,
                               recordName: String) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSchema.RecordType.valueColor,
            recordID: CKRecord.ID(recordName: recordName,
                                  zoneID: CloudKitSchema.zoneID))
        apply(valueColor, to: record)
        return record
    }

    package static func apply(_ valueColor: CloudValueColor, to record: CKRecord) {
        stampVersion(record)
        let values = record.encryptedValues
        values["key"] = valueColor.key
        values["value"] = valueColor.value
        values["color"] = valueColor.color
        values["modifiedAt"] = valueColor.modifiedAt
    }

    package static func valueColor(from record: CKRecord) throws -> CloudValueColor {
        try validate(record, as: CloudKitSchema.RecordType.valueColor)
        let values = record.encryptedValues
        return CloudValueColor(
            key: try require(values["key"] as? String, "key"),
            value: try require(values["value"] as? String, "value"),
            color: try require(values["color"] as? String, "color"),
            modifiedAt: try require(values["modifiedAt"] as? Date, "modifiedAt"))
    }

    // MARK: Label sets

    package static func record(for labelSet: CloudLabelSet) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSchema.RecordType.labelSet,
            recordID: CKRecord.ID(recordName: labelSet.uuid,
                                  zoneID: CloudKitSchema.zoneID))
        apply(labelSet, to: record)
        return record
    }

    package static func apply(_ labelSet: CloudLabelSet, to record: CKRecord) {
        stampVersion(record)
        let values = record.encryptedValues
        values["name"] = labelSet.name
        values["symbolName"] = labelSet.symbolName
        values["labels"] = encode(labels: labelSet.labels)
        values["quickLabels"] = encode(labels: labelSet.quickLabels)
        values["position"] = labelSet.position
        values["modifiedAt"] = labelSet.modifiedAt
    }

    package static func labelSet(from record: CKRecord) throws -> CloudLabelSet {
        try validate(record, as: CloudKitSchema.RecordType.labelSet)
        let values = record.encryptedValues
        return CloudLabelSet(
            uuid: record.recordID.recordName,
            name: try require(values["name"] as? String, "name"),
            symbolName: try require(values["symbolName"] as? String, "symbolName"),
            labels: try decodeLabels(try require(values["labels"] as? Data, "labels")),
            quickLabels: try decodeLabels(try require(values["quickLabels"] as? Data, "quickLabels")),
            position: try require(values["position"] as? Int, "position"),
            modifiedAt: try require(values["modifiedAt"] as? Date, "modifiedAt"))
    }

    // MARK: Preferences

    package static func record(for preferences: CloudPreferences) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSchema.RecordType.preferences,
            recordID: CKRecord.ID(recordName: CloudKitSchema.preferencesRecordName,
                                  zoneID: CloudKitSchema.zoneID))
        apply(preferences, to: record)
        return record
    }

    package static func apply(_ preferences: CloudPreferences, to record: CKRecord) {
        stampVersion(record)
        let values = record.encryptedValues
        values["colorByValue"] = preferences.colorByValue
        values["menuLabelSetLimit"] = preferences.menuLabelSetLimit
        values["modifiedAt"] = preferences.modifiedAt
    }

    package static func preferences(from record: CKRecord) throws -> CloudPreferences {
        try validate(record, as: CloudKitSchema.RecordType.preferences)
        let values = record.encryptedValues
        return CloudPreferences(
            colorByValue: try require(values["colorByValue"] as? Bool, "colorByValue"),
            menuLabelSetLimit: try require(values["menuLabelSetLimit"] as? Int, "menuLabelSetLimit"),
            modifiedAt: try require(values["modifiedAt"] as? Date, "modifiedAt"))
    }

    // MARK: Shared

    private static func stampVersion(_ record: CKRecord) {
        record[CloudKitSchema.versionKey] = CloudKitSchema.currentRecordVersion
    }

    private static func validate(_ record: CKRecord, as type: String) throws {
        guard record.recordType == type else {
            throw DecodeError.wrongRecordType(expected: type, got: record.recordType)
        }
        let version = record[CloudKitSchema.versionKey] as? Int ?? 0
        guard version <= CloudKitSchema.currentRecordVersion else {
            throw DecodeError.newerRecordVersion(version)
        }
    }

    private static func require<T>(_ value: T?, _ field: String) throws -> T {
        guard let value else { throw DecodeError.missingField(field) }
        return value
    }

    /// An ordered label list as one JSON payload. Sorted keys make equal
    /// lists byte-equal, so payload comparison can stand in for list
    /// comparison; element order is the array's and survives verbatim.
    private static func encode(labels: [SpanLabel]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Encoding [SpanLabel] (two Strings) cannot fail.
        return try! encoder.encode(labels)
    }

    private static func decodeLabels(_ data: Data) throws -> [SpanLabel] {
        do {
            return try JSONDecoder().decode([SpanLabel].self, from: data)
        } catch {
            throw DecodeError.missingField("labels: \(error.localizedDescription)")
        }
    }
}
#endif
