import Foundation
import MomentTallyCore

/// The Log tab's live filter (#51): whitespace-separated tokens where
/// `key:value` selects spans carrying that label and anything else is a
/// free-text term; all tokens must match (AND). A deliberately tiny parser,
/// kept apart from the view so the field can grow into the #52 query
/// language instead of being replaced.
package struct LogFilter: Equatable {
    /// One parsed `key:value` token. A bare value matches as a prefix; a
    /// quoted value (`client:"app"`) must match exactly — the escape hatch
    /// when one value prefixes another (`app` vs `app-server`).
    package struct Pair: Equatable {
        package var key: String
        package var value: String
        package var exact: Bool = false

        package init(key: String, value: String, exact: Bool = false) {
            self.key = key
            self.value = value
            self.exact = exact
        }
    }

    /// `key:value` tokens — the span must carry every one. Keys compare
    /// case-insensitively with surrounding whitespace ignored; bare values
    /// are prefixes, so the list narrows smoothly while one is typed, and
    /// the empty value (`client:`) is just the empty prefix — any span
    /// carrying the key.
    package var pairs: [Pair] = []
    /// Free-text tokens — each must appear as a case-insensitive substring
    /// somewhere in the span's label keys, label values, or note.
    package var terms: [String] = []

    package init(pairs: [Pair] = [], terms: [String] = []) {
        self.pairs = pairs
        self.terms = terms
    }

    package var isEmpty: Bool { pairs.isEmpty && terms.isEmpty }

    package static func parse(_ text: String) -> LogFilter {
        var filter = LogFilter()
        for token in tokenize(text) {
            if let colon = token.firstIndex(of: ":"),
               colon != token.startIndex, !token.hasPrefix("\"") {
                let rawValue = String(token[token.index(after: colon)...])
                filter.pairs.append(Pair(
                    key: String(token[..<colon]).replacingOccurrences(of: "\"", with: ""),
                    value: rawValue.replacingOccurrences(of: "\"", with: ""),
                    exact: rawValue.contains("\"")))
            } else {
                // A wholly quoted token is literal text even if it contains
                // a colon, and a stray leading colon (":a") is treated as
                // the term it was probably meant to be.
                let term = token.replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if !term.isEmpty { filter.terms.append(term) }
            }
        }
        return filter
    }

    /// Split on whitespace — plus the `{`, `}`, `,` of #52's selector
    /// punctuation, so a pasted `{client:a, project:website}` filters the
    /// same as the bare tokens. Double quotes suspend splitting, so
    /// `client:"acme corp"` stays one token (labels may contain spaces in
    /// their values, and quoting is how #52 will spell those too). The quote
    /// marks stay in the token: `parse` reads them as the exact-match signal.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if !inQuotes,
                      character.isWhitespace || "{},".contains(character) {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    package func matches(_ span: TimeSpan) -> Bool {
        for pair in pairs {
            guard span.labels.contains(where: { pairMatches(pair, $0) })
            else { return false }
        }
        for term in terms {
            let inLabels = span.labels.contains { termMatches(term, $0) }
            guard inLabels || span.note.lowercased().contains(term.lowercased())
            else { return false }
        }
        return true
    }

    /// True when the filter singles this label out — a `key:value` pair
    /// selects it, or a free-text term appears in its key or value. The Log
    /// view uses this to move matched pills to the front of a row.
    package func highlights(_ label: SpanLabel) -> Bool {
        pairs.contains { pairMatches($0, label) }
            || terms.contains { termMatches($0, label) }
    }

    /// `labels` reordered so highlighted ones come first, each group keeping
    /// its original order.
    package func highlightedFirst(_ labels: [SpanLabel]) -> [SpanLabel] {
        guard !isEmpty else { return labels }
        let hits = labels.filter(highlights)
        guard !hits.isEmpty else { return labels }
        return hits + labels.filter { !highlights($0) }
    }

    /// Keys and values compare with surrounding whitespace ignored, so
    /// `repo:foo` matches a label stored with a space typed after the colon
    /// (value " foo") — the pill reads "repo: foo" either way, and the search
    /// should find what the eye sees. A quoted empty value (`client:""`)
    /// requires an empty value, unlike the bare `client:` match-any.
    private func pairMatches(_ pair: Pair, _ label: SpanLabel) -> Bool {
        let wantKey = pair.key.trimmingCharacters(in: .whitespaces)
        let wantValue = pair.value.trimmingCharacters(in: .whitespaces)
        let key = label.key.trimmingCharacters(in: .whitespaces)
        let value = label.value.trimmingCharacters(in: .whitespaces)
        guard key.caseInsensitiveCompare(wantKey) == .orderedSame else { return false }
        return pair.exact
            ? value.caseInsensitiveCompare(wantValue) == .orderedSame
            : value.lowercased().hasPrefix(wantValue.lowercased())
    }

    private func termMatches(_ term: String, _ label: SpanLabel) -> Bool {
        let needle = term.lowercased()
        return label.key.lowercased().contains(needle)
            || label.value.lowercased().contains(needle)
    }
}
