import Foundation

// MARK: - Remote record shapes
//
// What the sync engine sees of the server: domain values plus `updatedAt`,
// the server-side half of last-writer-wins (server write time, whole
// seconds — see server/docs/api-v1.md "Sync"). These are *not* wire DTOs;
// `MomentTallyClient` maps GraphQL payloads into them at its boundary, and the
// engine's tests implement the same protocol with an in-memory fake.

package struct RemoteTimeSpan: Equatable {
    package let id: Int
    package let start: Date
    package let end: Date?         // nil == running
    package let note: String
    package let labels: [SpanLabel]
    package let updatedAt: Date

    package init(id: Int, start: Date, end: Date?, note: String,
                 labels: [SpanLabel], updatedAt: Date) {
        self.id = id
        self.start = start
        self.end = end
        self.note = note
        self.labels = labels
        self.updatedAt = updatedAt
    }
}

/// A timespan deletion the server remembers (a tombstone).
package struct RemoteDeletion: Equatable {
    package let id: Int
    package let deletedAt: Date

    package init(id: Int, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// One page of the timespan delta feed.
package struct RemoteTimeSpanChanges {
    package let timeSpans: [RemoteTimeSpan]
    package let deleted: [RemoteDeletion]
    package let hasMore: Bool
    package let now: Date

    package init(timeSpans: [RemoteTimeSpan], deleted: [RemoteDeletion],
                 hasMore: Bool, now: Date) {
        self.timeSpans = timeSpans
        self.deleted = deleted
        self.hasMore = hasMore
        self.now = now
    }
}

package struct RemoteValueColor: Equatable {
    package let value: String
    package let color: String
    package let updatedAt: Date

    package init(value: String, color: String, updatedAt: Date) {
        self.value = value
        self.color = color
        self.updatedAt = updatedAt
    }
}

package struct RemoteLabelDefinition: Equatable {
    package let key: String
    package let color: String
    package let valueColors: [RemoteValueColor]
    package let updatedAt: Date

    package init(key: String, color: String, valueColors: [RemoteValueColor],
                 updatedAt: Date) {
        self.key = key
        self.color = color
        self.valueColors = valueColors
        self.updatedAt = updatedAt
    }
}

/// A label set as the server holds it; `labels` are the ordered members and
/// `quickLabels` the ordered quick labels (#92), which ride the set's
/// snapshot — the set's `updatedAt` covers both lists.
/// Position on the server is the index in the `labelSets()` array.
package struct RemoteLabelSet: Equatable {
    package let id: Int
    package let name: String
    package let symbolName: String
    package let labels: [SpanLabel]
    package let quickLabels: [SpanLabel]
    package let updatedAt: Date

    package init(id: Int, name: String, symbolName: String,
                 labels: [SpanLabel], quickLabels: [SpanLabel] = [],
                 updatedAt: Date) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.labels = labels
        self.quickLabels = quickLabels
        self.updatedAt = updatedAt
    }
}

package struct RemotePreferences: Equatable {
    package let colorByValue: Bool
    package let menuLabelSetLimit: Int
    /// Zero-adjacent (`.distantPast` after mapping) when never set — any
    /// device's real edit wins over never-written defaults.
    package let updatedAt: Date

    package init(colorByValue: Bool, menuLabelSetLimit: Int, updatedAt: Date) {
        self.colorByValue = colorByValue
        self.menuLabelSetLimit = menuLabelSetLimit
        self.updatedAt = updatedAt
    }
}

/// Marks an error as a server-side *rejection* (a GraphQL error: "does not
/// exist", "already exists") as opposed to a transport failure. The engine
/// tolerates rejections where they mean the work is moot (deleting an
/// already-absent record) and falls back where they mean a race (creating a
/// key another device just created); transport failures abort the run and
/// everything stays queued.
package protocol ServerRejection: Error {}

// MARK: - The server surface the engine syncs against

/// The v1 operations reconciliation needs — implemented for real by
/// `MomentTallyClient` and in-process by the tests' fake server. Timespans
/// sync by delta feed; everything else by snapshot.
package protocol SyncServerAPI {
    /// Session probe: the signed-in user, or nil when the token is dead.
    func currentUser() async throws -> User?

    // Pull
    func timeSpanChanges(since: Date, afterId: Int) async throws -> RemoteTimeSpanChanges
    func labelDefinitions() async throws -> [RemoteLabelDefinition]
    func labelSets() async throws -> [RemoteLabelSet]
    func userPreferences() async throws -> RemotePreferences

    // Push — timespans
    func createTimeSpan(start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> Int
    func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws
    func removeTimeSpan(id: Int) async throws

    // Push — label definitions and value colors
    func createLabelDefinition(key: String, color: String) async throws
    func updateLabelDefinition(key: String, color: String) async throws
    func setLabelValueColor(key: String, value: String, color: String) async throws
    func clearLabelValueColor(key: String, value: String) async throws

    // Push — label sets (position rides along, see the v1 position args)
    func createLabelSet(name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws -> Int
    func updateLabelSet(id: Int, name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws
    func removeLabelSet(id: Int) async throws

    // Push — preferences
    func setUserPreferences(colorByValue: Bool, menuLabelSetLimit: Int) async throws
}
