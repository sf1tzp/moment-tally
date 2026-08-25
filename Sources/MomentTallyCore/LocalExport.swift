import Foundation
import GRDB

// MARK: - Export document (#57)

/// The JSON snapshot of everything the local store owns: timespans with their
/// labels, label definitions, per-value color overrides, and label sets with
/// their members. Schema-versioned so the format can evolve and a future
/// import can validate what it's reading; sync bookkeeping (dirty flags,
/// server mappings, tombstones) stays out — it describes a connection, not
/// the user's data.
package struct LocalExport: Codable, Equatable {
    /// Bump when the document shape changes, so an import can tell exactly
    /// what it has been handed.
    package static let currentSchemaVersion = 1

    package var schemaVersion = Self.currentSchemaVersion
    package var exportedAt: Date
    package var timeSpans: [Span]
    package var labelDefinitions: [LabelDefinition]
    package var valueColors: [ValueColor]
    package var labelSets: [LabelSet]
    /// Present only on partial (filtered) exports — see `Filter` in
    /// ExportFilter.swift. Nil (and omitted from the JSON) on full exports,
    /// which therefore encode exactly as they did before the field existed.
    package var filter: Filter?

    /// One timespan with its labels inline, in display order. `id` is the
    /// local rowid — exported so spans can be cross-referenced, not promised
    /// stable across databases. A nil `end` is a still-running span.
    package struct Span: Codable, Equatable {
        package var id: Int64
        package var start: Date
        package var end: Date?
        package var note: String
        package var labels: [Label]
    }

    package struct Label: Codable, Equatable {
        package var key: String
        package var value: String

        // The compiler-generated memberwise init is capped at internal, so
        // cross-module callers (the CLI) need this spelled out.
        package init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    package struct ValueColor: Codable, Equatable {
        package var key: String
        package var value: String
        package var color: String
    }

    /// A label set and its member labels. Array order carries the launcher
    /// and member positions, the way the UI shows them.
    package struct LabelSet: Codable, Equatable {
        package var id: String
        package var name: String
        package var symbol: String?
        /// Fallback launcher-card color ("#rrggbb") for a set with no
        /// labels. Nil (and omitted from the JSON, like `filter`) when unset,
        /// so colorless exports encode exactly as before the field existed.
        package var color: String?
        /// Per-card gradient toggle (#226). Nil (and omitted, like `color`)
        /// when unset — meaning gradient on.
        package var gradient: Bool?
        package var labels: [Label]
        /// The set's quick labels (#92), in offer order. Nil (and omitted,
        /// like `color`) when the set has none.
        package var quickLabels: [Label]?
    }

    // MARK: Wire format

    /// Dates are ISO 8601 with the exporting machine's UTC offset and
    /// millisecond precision — unambiguous across timezones, and exactly the
    /// precision GRDB stores.
    package static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }

    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let formatter = dateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    /// The import counterpart's decoder, here so tests prove the round trip
    /// the schema-versioned format is designed for.
    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = dateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }
}

// MARK: - LocalBackend surface

package extension LocalBackend {
    /// Snapshot the whole store as an export document, in one read
    /// transaction so the result is a consistent point in time. Synchronous
    /// like the tag-set surface: Settings calls it from a button press and
    /// the store is a single local file.
    func exportData(at now: Date = Date()) throws -> LocalExport {
        try dbQueue.read { db in
            let spanRows = try TimeSpanRow
                .order(Column("start"), Column("id"))
                .fetchAll(db)
            let labelRows = try SpanLabelRow.order(Column("rowid")).fetchAll(db)
            let labelsBySpan = Dictionary(grouping: labelRows, by: \.spanId)
            let spans = spanRows.map { row in
                LocalExport.Span(
                    id: row.id!, start: row.start, end: row.end, note: row.note,
                    labels: (labelsBySpan[row.id!] ?? []).map {
                        LocalExport.Label(key: $0.key, value: $0.value)
                    })
            }

            let definitions = try LabelDefinition.order(Column("key")).fetchAll(db)

            let colors = try ValueColorRow
                .order(Column("key"), Column("value"))
                .fetchAll(db)
                .map { LocalExport.ValueColor(key: $0.key, value: $0.value, color: $0.color) }

            let setRows = try LabelSetRow.order(Column("position")).fetchAll(db)
            let memberRows = try LabelSetMemberRow.order(Column("position")).fetchAll(db)
            let membersBySet = Dictionary(grouping: memberRows, by: \.setId)
            let quickRows = try LabelSetQuickMemberRow.order(Column("position")).fetchAll(db)
            let quickBySet = Dictionary(grouping: quickRows, by: \.setId)
            let sets = setRows.map { row in
                let quick = (quickBySet[row.id] ?? []).map {
                    LocalExport.Label(key: $0.key, value: $0.value)
                }
                return LocalExport.LabelSet(
                    id: row.id, name: row.name, symbol: row.symbol,
                    color: row.color, gradient: row.gradient,
                    labels: (membersBySet[row.id] ?? []).map {
                        LocalExport.Label(key: $0.key, value: $0.value)
                    },
                    quickLabels: quick.isEmpty ? nil : quick)
            }

            return LocalExport(exportedAt: now, timeSpans: spans,
                               labelDefinitions: definitions,
                               valueColors: colors, labelSets: sets)
        }
    }

    /// `exportData` serialised for a save panel: pretty-printed JSON with
    /// deterministic key order.
    func exportJSON(at now: Date = Date()) throws -> Data {
        try LocalExport.encoder().encode(exportData(at: now))
    }
}
