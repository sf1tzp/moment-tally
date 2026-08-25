import Foundation

// MARK: - Domain types
//
// The app's own vocabulary: a *label* is a `key: value` dimension attached to
// a timespan, so time can be sliced along any axis later (the Prometheus
// mental model — time series with dimensions). Backends translate these to and
// from their own wire shapes; nothing here knows about GraphQL or RFC3339.

/// The signed-in account a backend serves data for. Decodable because its wire
/// shape already is the domain shape — no separate DTO needed.
package struct User: Decodable, Equatable {
    package let id: Int
    package let name: String
    package let admin: Bool

    package init(id: Int, name: String, admin: Bool) {
        self.id = id
        self.name = name
        self.admin = admin
    }
}

/// A key/value pair attached to a timespan — e.g. `recipe: sourdough`.
package struct SpanLabel: Hashable {
    package let key: String
    package let value: String

    package init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A label key's definition: the key itself plus its display color (a hex
/// string like "#2196f3"). Colors are stored per *key*; per-value colors are
/// a client-side overlay (see `AppModel.valueColors`). Codable so the local
/// store can persist it directly as a GRDB record — the type is its own row.
package struct LabelDefinition: Hashable, Codable {
    package let key: String
    package let color: String

    package init(key: String, color: String) {
        self.key = key
        self.color = color
    }
}

/// A tracked interval of time, possibly still running, with its labels.
package struct TimeSpan: Identifiable, Equatable {
    package let id: Int
    package let start: Date
    package let end: Date?      // nil == currently running
    package let note: String
    package let labels: [SpanLabel]

    package var isRunning: Bool { end == nil }

    package init(id: Int, start: Date, end: Date?, note: String, labels: [SpanLabel]) {
        self.id = id
        self.start = start
        self.end = end
        self.note = note
        self.labels = labels
    }
}

// MARK: - Paging

/// An opaque paging token. Backends serialise whatever state their own page
/// walk needs into `rawValue` (traggo: its stable-cursor JSON); callers only
/// hand a token back to the backend that minted it.
package struct PageToken: Equatable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One page of finished timespans, plus the token for the next page — nil when
/// the walk is complete.
package struct TimeSpanPage {
    package let timeSpans: [TimeSpan]
    package let nextPage: PageToken?

    package init(timeSpans: [TimeSpan], nextPage: PageToken?) {
        self.timeSpans = timeSpans
        self.nextPage = nextPage
    }
}

// MARK: - Backend

/// The storage seam between the state layer and wherever timespans actually
/// live. Today the only implementation is `TraggoClient` (a traggo server over
/// GraphQL); a local store and a Moment Tally sync backend implement the same
/// surface later.
///
/// Deliberately data-only: session lifecycle (login, logout, tokens) is a
/// per-backend concern owned by whoever constructs the backend — a local store
/// has no notion of logging in.
package protocol Backend {
    /// The user this backend serves, or nil when it isn't ready to (e.g. an
    /// expired token). Doubles as the readiness probe.
    func currentUser() async throws -> User?

    /// All currently-running timespans (end == nil).
    func timers() async throws -> [TimeSpan]

    /// Every known label definition (keys with colors).
    func labelDefinitions() async throws -> [LabelDefinition]

    /// Register a new label key with a color. Backends may require this
    /// before the key can appear on a timespan (traggo rejects unknown keys).
    func createLabelDefinition(key: String, color: String) async throws

    /// Change the color of an existing label key, everywhere it's used.
    func updateLabelDefinition(key: String, color: String) async throws

    /// Start a running timespan (no end time).
    func startTimeSpan(start: Date, labels: [SpanLabel], note: String) async throws -> TimeSpan

    /// Update a timespan in place. Every field is written, so callers pass the
    /// current values for anything they're not changing. A nil `end` leaves
    /// the timespan running.
    func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> TimeSpan

    /// Stop a running timespan.
    func stopTimeSpan(id: Int, end: Date) async throws -> TimeSpan

    /// Delete a timespan.
    func removeTimeSpan(id: Int) async throws

    /// One page of *finished* timespans overlapping [from, to], newest first;
    /// pass the previous page's `nextPage` token to continue the walk. Running
    /// timespans are excluded — merge in `timers()` for a complete picture.
    func timeSpans(from: Date, to: Date, page: PageToken?) async throws -> TimeSpanPage
}

package extension Backend {
    /// Make sure every tag's key exists as a definition, creating missing ones
    /// with the default color. Idempotent where `createLabelDefinition` is
    /// deliberately not: the existing keys are read fresh from the backend (a
    /// caller's stale cache must not turn "already exists" into a duplicate-
    /// insert error), and a key appearing on several tags is created once.
    /// Returns the definitive definition list, in the backend's order, so
    /// callers can refresh their caches from it.
    @discardableResult
    func ensureLabelDefinitions(for tags: [SpanLabel],
                                defaultColor: String) async throws -> [LabelDefinition] {
        let definitions = try await labelDefinitions()
        var known = Set(definitions.map(\.key))
        var createdAny = false
        for tag in tags where known.insert(tag.key).inserted {
            try await createLabelDefinition(key: tag.key, color: defaultColor)
            createdAny = true
        }
        // Re-fetch rather than append locally, so the returned list carries
        // whatever ordering and defaults the backend applied.
        return createdAny ? try await labelDefinitions() : definitions
    }
}
