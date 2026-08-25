import Foundation

// MARK: - Export filtering (#80)
//
// The CLI's `moment-tally export --from/--to/--include/--exclude` narrows the
// export document to matching timespans. The logic lives here, not in the
// CLI target, so the semantics are testable next to the export they filter —
// and so a future importer can share the selector vocabulary.

/// One `--include`/`--exclude` selector: `key:value` matches a span carrying
/// exactly that label; a bare `key` matches a span carrying any label with
/// that key. The split is on the *first* ":" — label values may themselves
/// contain ":", keys never do.
package struct LabelSelector: Equatable {
    package let key: String
    /// nil for a bare-key selector.
    package let value: String?

    /// Parses a raw selector; nil when the key part is empty.
    package init?(_ raw: String) {
        if let colon = raw.firstIndex(of: ":") {
            key = String(raw[..<colon])
            value = String(raw[raw.index(after: colon)...])
        } else {
            key = raw
            value = nil
        }
        if key.isEmpty { return nil }
    }

    /// The canonical spelling, recorded in the export's filter block.
    package var rawValue: String {
        value.map { "\(key):\($0)" } ?? key
    }

    package func matches(_ labels: [LocalExport.Label]) -> Bool {
        labels.contains { label in
            label.key == key && (value == nil || label.value == value)
        }
    }
}

/// A resolved export filter: concrete instant bounds plus label selectors,
/// carrying the raw day strings for the document's filter record.
package struct ExportFilter: Equatable {
    package struct ParseError: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// Inclusive lower bound (local midnight of `--from`); nil = unbounded.
    package var from: Date?
    /// Exclusive upper bound (local midnight *after* `--to`); nil = unbounded.
    package var until: Date?
    /// The day strings as requested, recorded verbatim in the document.
    package var fromDay: String?
    package var toDay: String?
    package var include: [LabelSelector]
    package var exclude: [LabelSelector]

    /// Resolve raw CLI arguments. Day strings are `YYYY-MM-DD`, interpreted
    /// as *local* days of the exporting machine — the same clock that stamps
    /// the document's dates with its UTC offset.
    package init(fromDay: String? = nil, toDay: String? = nil,
                 include: [String] = [], exclude: [String] = [],
                 calendar: Calendar = .current) throws {
        func day(_ raw: String) throws -> Date {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: raw) else {
                throw ParseError(message: "Not a date (expected YYYY-MM-DD): \(raw)")
            }
            return calendar.startOfDay(for: date)
        }
        func selectors(_ raw: [String], flag: String) throws -> [LabelSelector] {
            try raw.map {
                guard let selector = LabelSelector($0) else {
                    throw ParseError(message: "Not a label selector (expected key or key:value): \(flag) \($0)")
                }
                return selector
            }
        }

        self.fromDay = fromDay
        self.toDay = toDay
        from = try fromDay.map(day)
        if let toDay {
            let start = try day(toDay)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw ParseError(message: "Not a date (expected YYYY-MM-DD): \(toDay)")
            }
            until = end
        }
        if let from, let until, from >= until {
            throw ParseError(message: "--from \(fromDay!) is after --to \(toDay!)")
        }
        self.include = try selectors(include, flag: "--include")
        self.exclude = try selectors(exclude, flag: "--exclude")
    }

    package var isEmpty: Bool {
        from == nil && until == nil && include.isEmpty && exclude.isEmpty
    }

    /// Whether a span survives the filter. Date bounds keep any span whose
    /// interval *overlaps* [from, until) — a span crossing midnight into the
    /// range belongs to it, matching the store's own range query. A running
    /// span is treated as extending indefinitely. Every `include` must match
    /// (AND); any matching `exclude` drops the span — exclude wins.
    package func keeps(_ span: LocalExport.Span) -> Bool {
        if let until, span.start >= until { return false }
        if let from, let end = span.end, end < from { return false }
        for selector in include where !selector.matches(span.labels) { return false }
        for selector in exclude where selector.matches(span.labels) { return false }
        return true
    }
}

package extension LocalExport {
    /// The filtered-ness record: present exactly when the document is a
    /// partial export, so it can't silently masquerade as a full backup.
    /// `from`/`to` are the requested local days verbatim; `include`/`exclude`
    /// the selectors as given. Optional and omitted when absent, so full
    /// exports are byte-identical to schema v1 before this field existed.
    struct Filter: Codable, Equatable {
        package var from: String?
        package var to: String?
        package var include: [String]?
        package var exclude: [String]?

        package init(from: String? = nil, to: String? = nil,
                     include: [String]? = nil, exclude: [String]? = nil) {
            self.from = from
            self.to = to
            self.include = include
            self.exclude = exclude
        }
    }

    /// A copy narrowed to the timespans the filter keeps, with the filter
    /// recorded. Label definitions, value colors, and label sets are
    /// configuration, not time data — they pass through untouched, so the
    /// document stays valid importer input. An empty filter returns the
    /// document unchanged, with no filter record.
    func filtered(_ filter: ExportFilter) -> LocalExport {
        guard !filter.isEmpty else { return self }
        var copy = self
        copy.timeSpans = timeSpans.filter(filter.keeps)
        copy.filter = Filter(
            from: filter.fromDay,
            to: filter.toDay,
            include: filter.include.isEmpty ? nil : filter.include.map(\.rawValue),
            exclude: filter.exclude.isEmpty ? nil : filter.exclude.map(\.rawValue))
        return copy
    }
}
