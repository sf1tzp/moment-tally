import Foundation
@testable import MomentTally
@testable import MomentTallyCore

/// An in-process v1 sync server: the same `SyncServerAPI` surface
/// `MomentTallyClient` implements over GraphQL, backed by dictionaries — the
/// importer's LocalBackend-to-LocalBackend testing idea, generalised. It
/// mirrors the real server's sync semantics: `updatedAt` stamped from a
/// controllable clock, the (since, afterId) delta feed with (updatedAt, id)
/// ordering and paging, `deletedAt >= since` tombstone re-delivery, and
/// rejections (thrown as `ServerRejection`) for missing/duplicate records.
final class FakeSyncServer: SyncServerAPI {
    struct Rejection: Error, ServerRejection { let message: String }
    struct Offline: Error {}

    /// The server clock; tests move it to stage last-writer-wins races.
    var now = Date()
    /// When true every call throws `Offline` (a transport failure, not a
    /// rejection) — the offline-queue scenario.
    var offline = false
    /// Page size of the delta feed.
    var pageLimit = 200

    private(set) var spans: [Int: RemoteTimeSpan] = [:]
    private(set) var deletions: [Int: Date] = [:]                    // id → deletedAt
    private(set) var definitions: [String: RemoteLabelDefinition] = [:]
    private(set) var sets: [Int: RemoteLabelSet] = [:]
    private(set) var positions: [Int: Int] = [:]                     // set id → position
    private(set) var preferences = RemotePreferences(
        colorByValue: true, menuLabelSetLimit: 5, updatedAt: .distantPast)
    private(set) var preferencesEverSet = false

    private var nextSpanId = 1
    private var nextSetId = 1

    /// Every delta-feed call, for checkpoint assertions.
    private(set) var changesCalls: [(since: Date, afterId: Int)] = []

    private func checkOnline() throws {
        if offline { throw Offline() }
    }

    // MARK: Seeding helpers (what "another device" did)

    @discardableResult
    func seedSpan(start: Date, end: Date?, note: String = "",
                  labels: [SpanLabel] = []) -> Int {
        let id = nextSpanId
        nextSpanId += 1
        spans[id] = RemoteTimeSpan(id: id, start: start, end: end, note: note,
                                   labels: labels, updatedAt: now)
        return id
    }

    func seedDefinition(key: String, color: String,
                        valueColors: [(value: String, color: String)] = []) {
        definitions[key] = RemoteLabelDefinition(
            key: key, color: color,
            valueColors: valueColors.map {
                RemoteValueColor(value: $0.value, color: $0.color, updatedAt: now)
            },
            updatedAt: now)
    }

    @discardableResult
    func seedSet(name: String, symbol: String = "tag", labels: [SpanLabel] = [],
                 quickLabels: [SpanLabel] = []) -> Int {
        let id = nextSetId
        nextSetId += 1
        sets[id] = RemoteLabelSet(id: id, name: name, symbolName: symbol,
                                  labels: labels, quickLabels: quickLabels,
                                  updatedAt: now)
        positions[id] = (positions.values.max() ?? -1) + 1
        return id
    }

    /// The launcher order, for assertions.
    var orderedSetNames: [String] {
        sets.values
            .sorted { positions[$0.id] ?? 0 < positions[$1.id] ?? 0 }
            .map(\.name)
    }

    // MARK: SyncServerAPI — session

    func currentUser() async throws -> User? {
        try checkOnline()
        return User(id: 1, name: "fake", admin: false)
    }

    // MARK: SyncServerAPI — pull

    func timeSpanChanges(since: Date, afterId: Int) async throws -> RemoteTimeSpanChanges {
        try checkOnline()
        changesCalls.append((since, afterId))
        var changed = spans.values
            .filter { $0.updatedAt > since || ($0.updatedAt == since && $0.id > afterId) }
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
        let hasMore = changed.count > pageLimit
        if hasMore { changed = Array(changed.prefix(pageLimit)) }
        let deleted = deletions
            .filter { $0.value >= since && spans[$0.key] == nil }
            .map { RemoteDeletion(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.id < $1.id }
        return RemoteTimeSpanChanges(timeSpans: changed, deleted: deleted,
                                     hasMore: hasMore, now: now)
    }

    func labelDefinitions() async throws -> [RemoteLabelDefinition] {
        try checkOnline()
        return definitions.values.sorted { $0.key < $1.key }
    }

    func labelSets() async throws -> [RemoteLabelSet] {
        try checkOnline()
        return sets.values.sorted { positions[$0.id] ?? 0 < positions[$1.id] ?? 0 }
    }

    func userPreferences() async throws -> RemotePreferences {
        try checkOnline()
        return preferences
    }

    // MARK: SyncServerAPI — timespans

    func createTimeSpan(start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> Int {
        try checkOnline()
        try requireDefinitions(for: labels)
        let id = nextSpanId
        nextSpanId += 1
        spans[id] = RemoteTimeSpan(id: id, start: start, end: end, note: note,
                                   labels: labels, updatedAt: now)
        return id
    }

    func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws {
        try checkOnline()
        guard spans[id] != nil else {
            throw Rejection(message: "time span with id \(id) does not exist")
        }
        try requireDefinitions(for: labels)
        spans[id] = RemoteTimeSpan(id: id, start: start, end: end, note: note,
                                   labels: labels, updatedAt: now)
    }

    func removeTimeSpan(id: Int) async throws {
        try checkOnline()
        guard spans.removeValue(forKey: id) != nil else {
            throw Rejection(message: "timespan with id \(id) does not exist")
        }
        deletions[id] = now
    }

    private func requireDefinitions(for labels: [SpanLabel]) throws {
        for label in labels where definitions[label.key] == nil {
            throw Rejection(message: "tag '\(label.key)' does not exist")
        }
    }

    // MARK: SyncServerAPI — definitions and value colors

    func createLabelDefinition(key: String, color: String) async throws {
        try checkOnline()
        guard definitions[key] == nil else {
            throw Rejection(message: "tag with key '\(key)' does already exist")
        }
        definitions[key] = RemoteLabelDefinition(key: key, color: color,
                                                 valueColors: [], updatedAt: now)
    }

    func updateLabelDefinition(key: String, color: String) async throws {
        try checkOnline()
        guard let existing = definitions[key] else {
            throw Rejection(message: "tag with key '\(key)' does not exist")
        }
        definitions[key] = RemoteLabelDefinition(key: key, color: color,
                                                 valueColors: existing.valueColors,
                                                 updatedAt: now)
    }

    func setLabelValueColor(key: String, value: String, color: String) async throws {
        try checkOnline()
        guard let existing = definitions[key] else {
            throw Rejection(message: "label definition with key '\(key)' does not exist")
        }
        var colors = existing.valueColors.filter { $0.value != value }
        colors.append(RemoteValueColor(value: value, color: color, updatedAt: now))
        colors.sort { $0.value < $1.value }
        definitions[key] = RemoteLabelDefinition(key: key, color: existing.color,
                                                 valueColors: colors,
                                                 updatedAt: existing.updatedAt)
    }

    func clearLabelValueColor(key: String, value: String) async throws {
        try checkOnline()
        guard let existing = definitions[key] else {
            throw Rejection(message: "label definition with key '\(key)' does not exist")
        }
        definitions[key] = RemoteLabelDefinition(
            key: key, color: existing.color,
            valueColors: existing.valueColors.filter { $0.value != value },
            updatedAt: existing.updatedAt)
    }

    // MARK: SyncServerAPI — label sets

    func createLabelSet(name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws -> Int {
        try checkOnline()
        let id = nextSetId
        nextSetId += 1
        sets[id] = RemoteLabelSet(id: id, name: name, symbolName: symbolName,
                                  labels: labels, quickLabels: quickLabels,
                                  updatedAt: now)
        positions[id] = (positions.values.max() ?? -1) + 1
        reposition(id: id, to: position)
        return id
    }

    func updateLabelSet(id: Int, name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws {
        try checkOnline()
        guard sets[id] != nil else {
            throw Rejection(message: "label set with id \(id) does not exist")
        }
        sets[id] = RemoteLabelSet(id: id, name: name, symbolName: symbolName,
                                  labels: labels, quickLabels: quickLabels,
                                  updatedAt: now)
        reposition(id: id, to: position)
    }

    func removeLabelSet(id: Int) async throws {
        try checkOnline()
        guard sets.removeValue(forKey: id) != nil else {
            throw Rejection(message: "label set with id \(id) does not exist")
        }
        positions.removeValue(forKey: id)
    }

    /// Move a set to a 0-based position (clamped) and renumber, bumping
    /// `updatedAt` only on sets that actually moved — like the real server.
    private func reposition(id: Int, to position: Int) {
        var ordered = sets.values
            .sorted { positions[$0.id] ?? 0 < positions[$1.id] ?? 0 }
            .map(\.id)
        guard let from = ordered.firstIndex(of: id) else { return }
        let clamped = max(0, min(position, ordered.count - 1))
        ordered.remove(at: from)
        ordered.insert(id, at: clamped)
        for (index, setId) in ordered.enumerated() where positions[setId] != index {
            positions[setId] = index
            if let set = sets[setId], setId != id {
                sets[setId] = RemoteLabelSet(id: set.id, name: set.name,
                                             symbolName: set.symbolName,
                                             labels: set.labels,
                                             quickLabels: set.quickLabels,
                                             updatedAt: now)
            }
        }
    }

    // MARK: SyncServerAPI — preferences

    func setUserPreferences(colorByValue: Bool, menuLabelSetLimit: Int) async throws {
        try checkOnline()
        preferences = RemotePreferences(colorByValue: colorByValue,
                                        menuLabelSetLimit: menuLabelSetLimit,
                                        updatedAt: now)
        preferencesEverSet = true
    }
}
