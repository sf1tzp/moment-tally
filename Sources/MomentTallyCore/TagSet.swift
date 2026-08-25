import Foundation

/// One editable tag inside a tag set. It carries a stable `id` so SwiftUI list
/// editing keeps field focus as you type — but that `id` is local only and
/// never persisted to the backend (we convert to `SpanLabel` at the boundary).
package struct TagRow: Identifiable, Codable, Hashable {
    package var id = UUID()
    package var key: String = ""
    package var value: String = ""

    package init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// A named bundle of tags the user can start with one click — "label set" in
/// UI copy (the type name predates the tag→label rename, #27). Persisted in
/// the local database and carried by sync (#92), so a user's sets follow
/// their account across connected Macs.
package struct TagSet: Identifiable, Codable, Hashable {
    package var id = UUID()
    package var name: String = ""
    package var tags: [TagRow] = []
    /// Icon shown on the set's launcher card: an SF Symbol name, or
    /// `markSymbol` for the brand mark. Optional so sets saved before icons
    /// existed keep decoding; `symbol` supplies the default.
    package var symbolName: String?
    /// "#rrggbb" fallback color for the set's launcher card, used only when
    /// the set has no labels to borrow a color from (a quick-labels-only
    /// set). Local-only — not part of the sync payload. Optional so older
    /// saves keep decoding; nil means the accent color.
    package var colorHex: String?
    /// Whether the launcher card (and the popover's mini tile) draws the
    /// Studio tile gradient (#201) rather than a flat fill. Per-card (#226):
    /// some colors don't benefit, and neighbouring hues clash as gradients
    /// side by side. Local-only like `colorHex`. Optional so older saves keep
    /// decoding; nil means on — the default of the global preference this
    /// replaced (see `showsGradient`).
    package var gradient: Bool?

    package init(id: UUID = UUID(), name: String = "", tags: [TagRow] = [],
                 symbolName: String? = nil, colorHex: String? = nil,
                 gradient: Bool? = nil) {
        self.id = id
        self.name = name
        self.tags = tags
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.gradient = gradient
    }

    /// The gradient choice to render — unset means gradient on.
    package var showsGradient: Bool { gradient ?? true }

    /// Reserved `symbolName` standing for the Moment Tally mark rather than
    /// an SF Symbol. It has to be a string, not the absence of one: sync
    /// declares `symbolName: String!` and flattens nil on both legs, so a set
    /// that simply had no icon would come back from the server as a literal
    /// "tag" and lose the mark on the next round trip. Dashes keep it clear
    /// of Apple's dot-separated namespace, so no future SF Symbol can claim
    /// it out from under us.
    package static let markSymbol = "moment-tally.mark"

    /// The symbol to render for this set. Unset means the brand mark.
    package var symbol: String { symbolName ?? Self.markSymbol }

    /// The domain form for starting a timespan. Traggo lower-cases tag keys
    /// and forbids spaces, so we normalise here to match how definitions are
    /// stored.
    package var labels: [SpanLabel] { tags.labels }

    /// The labels to start when a quick label rides along: the set's tags plus
    /// the quick label — *replacing* the set's value for the same key, because
    /// a quick label hones a set (`type: review` over the set's baked-in
    /// `type: programming`) rather than double-labelling it.
    package func labels(applying quick: TagRow) -> [SpanLabel] {
        let key = normalizeKey(quick.key)
        return (tags.filter { normalizeKey($0.key) != key } + [quick]).labels
    }

    /// Whether a timespan carrying these labels counts as *this set* running —
    /// the Launcher card's dim-while-running rule. True on any labelling a
    /// start from the set can produce: the set's own labels, or the labels a
    /// quick-label chip starts (`labels(applying:)` per quick) — a set is no
    /// less "running" for having been honed at start. Within a candidate
    /// labelling, a value-less label (`issue:` — the fill-in-the-value-per-
    /// start workflow, #149) is a slot, not a literal: it matches whatever
    /// value the span carries for that key, since the value arrives in the
    /// editor moments after the start. The key itself must still be there.
    package func matches(spanLabels: [SpanLabel], quicks: [TagRow]) -> Bool {
        let candidates = [labels] + quicks.map { labels(applying: $0) }
        return candidates.contains { want in
            let slots = Set(want.filter(\.value.isEmpty).map(\.key))
            let got = spanLabels.map {
                slots.contains($0.key) ? SpanLabel(key: $0.key, value: "") : $0
            }
            return Set(got) == Set(want)
        }
    }
}

/// Traggo tag keys must be lower-case with no spaces. Surrounding whitespace
/// is a typo, not intent, so it's trimmed rather than turned into dashes.
package func normalizeKey(_ key: String) -> String {
    key.trimmingCharacters(in: .whitespaces)
        .lowercased().replacingOccurrences(of: " ", with: "-")
}

/// The composite dictionary key for per-`key: value` color overrides — a unit
/// separator rather than ":" because tag values may themselves contain ":".
/// Shared between `AppModel` (which keys its in-memory dictionary this way,
/// and the legacy UserDefaults store with it) and `LocalBackend` (which splits
/// the composite back into real columns).
package enum ValueColorKey {
    package static let separator: Character = "\u{1F}"

    package static func join(_ key: String, _ value: String) -> String {
        "\(key)\(separator)\(value)"
    }

    package static func split(_ raw: String) -> (key: String, value: String)? {
        guard let index = raw.firstIndex(of: separator) else { return nil }
        return (String(raw[..<index]), String(raw[raw.index(after: index)...]))
    }

    /// Overrides after a label rewrite: colors follow the labels they
    /// described. `fromValue` nil moves every override under the key (a key
    /// rename); otherwise one `key: value` pair moves, landing on
    /// `toValue ?? fromValue` (mirroring how the rewrite keeps a span's value
    /// when no new one is given). An override already at the destination wins
    /// — it was chosen for that spelling — and the source override is dropped
    /// either way.
    package static func migrating(_ colors: [String: String],
                                  fromKey: String, fromValue: String?,
                                  toKey: String, toValue: String?) -> [String: String] {
        let from = normalizeKey(fromKey)
        let to = normalizeKey(toKey)
        var colors = colors
        func move(value: String, toValue: String) {
            guard let hex = colors.removeValue(forKey: join(from, value)) else { return }
            // A cleared value has no override slot.
            guard !toValue.isEmpty else { return }
            let target = join(to, toValue)
            if colors[target] == nil { colors[target] = hex }
        }
        if let fromValue {
            move(value: fromValue, toValue: toValue ?? fromValue)
        } else {
            for composite in colors.keys where composite.hasPrefix("\(from)\(separator)") {
                guard let (_, value) = split(composite) else { continue }
                move(value: value, toValue: value)
            }
        }
        return colors
    }
}

package extension [TagRow] {
    /// Drop empty rows, normalise keys, and trim values — the domain form for
    /// any mutation. Editors bind their fields to the raw rows (trimming per
    /// keystroke would forbid typing internal spaces), so surrounding
    /// whitespace is shed here, at the storage boundary.
    var labels: [SpanLabel] {
        filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { SpanLabel(key: normalizeKey($0.key),
                             value: $0.value.trimmingCharacters(in: .whitespaces)) }
    }

}

package extension Array where Element: Identifiable, Element.ID == UUID {
    /// Drag-to-reorder (#155): the element with `id` takes the drop target's
    /// position, shifting the elements between them. Returns false when
    /// either is missing — an element dragged in from a different list — so
    /// the drop can bounce back instead of landing. Generic because two kinds
    /// of list reorder this way: label rows within a set, and the sets
    /// themselves via their Launcher cards (#178).
    @discardableResult
    mutating func moveRow(_ id: UUID, onto targetID: UUID) -> Bool {
        guard let from = firstIndex(where: { $0.id == id }),
              let to = firstIndex(where: { $0.id == targetID })
        else { return false }
        if from != to { insert(remove(at: from), at: to) }
        return true
    }
}
