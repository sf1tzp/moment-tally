import Foundation
import MomentTallyCore

/// A thin GraphQL client for the Moment Tally v1 API (server/docs/api-v1.md),
/// hand-rolled over URLSession in the style of `TraggoClient` — typed
/// operations, wire DTOs mapped to engine shapes at this boundary. It
/// implements `SyncServerAPI` for the sync engine, plus the session
/// operation (`login`) that mints the device token.
///
/// Auth is unchanged in shape from the traggo lineage: the header is
/// `Authorization: traggo <token>` (literally "traggo"). The `Time` scalar
/// is the same RFC3339 wire form, so `TraggoTime` is reused for it.
struct MomentTallyClient: SyncServerAPI {
    var baseURL: URL
    var token: String?

    /// The server rejected the operation (a GraphQL error). Distinguished
    /// from transport failures so the sync engine can tolerate rejections
    /// that mean "already done" without swallowing real outages.
    struct RejectionError: LocalizedError, ServerRejection {
        let message: String
        var errorDescription: String? { message }
    }

    /// Anything that isn't a server answer: HTTP failures, no response,
    /// undecodable payloads. (URLSession's own errors pass through as-is.)
    struct TransportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: GraphQL envelopes

    private struct RequestBody<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    private struct ResponseBody<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable { let message: String }

    struct NoVariables: Encodable {}

    private func run<Variables: Encodable, Payload: Decodable>(
        _ query: String,
        variables: Variables,
        as _: Payload.Type
    ) async throws -> Payload {
        var request = URLRequest(url: baseURL.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("traggo \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(query: query, variables: variables))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TransportError(message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TransportError(message: "HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody<Payload>.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            throw RejectionError(message: errors.map(\.message).joined(separator: "\n"))
        }
        guard let payload = decoded.data else {
            throw TransportError(message: "Empty response")
        }
        return payload
    }

    // MARK: Wire DTOs (mirror schema.graphql; `TraggoTime` is the Time scalar)

    private struct WireLabel: Codable {
        let key: String
        let value: String

        init(_ label: SpanLabel) {
            key = label.key
            value = label.value
        }

        var domain: SpanLabel { SpanLabel(key: key, value: value) }
    }

    private struct WireTimeSpan: Decodable {
        let id: Int
        let start: TraggoTime
        let end: TraggoTime?
        let note: String
        let labels: [WireLabel]?
        let updatedAt: TraggoTime

        var remote: RemoteTimeSpan {
            RemoteTimeSpan(id: id, start: start.date, end: end?.date, note: note,
                           labels: (labels ?? []).map(\.domain),
                           updatedAt: updatedAt.date)
        }
    }

    private struct WireValueColor: Decodable {
        let value: String
        let color: String
        let updatedAt: TraggoTime
    }

    private struct WireLabelDefinition: Decodable {
        let key: String
        let color: String
        let valueColors: [WireValueColor]?
        let updatedAt: TraggoTime

        var remote: RemoteLabelDefinition {
            RemoteLabelDefinition(
                key: key, color: color,
                valueColors: (valueColors ?? []).map {
                    RemoteValueColor(value: $0.value, color: $0.color,
                                     updatedAt: $0.updatedAt.date)
                },
                updatedAt: updatedAt.date)
        }
    }

    private struct WireLabelSet: Decodable {
        let id: Int
        let name: String
        let symbolName: String
        let labels: [WireLabel]?
        let quickLabels: [WireLabel]?
        let updatedAt: TraggoTime

        var remote: RemoteLabelSet {
            RemoteLabelSet(id: id, name: name, symbolName: symbolName,
                           labels: (labels ?? []).map(\.domain),
                           quickLabels: (quickLabels ?? []).map(\.domain),
                           updatedAt: updatedAt.date)
        }
    }

    // MARK: Session (not part of SyncServerAPI)

    func login(username: String, password: String, deviceName: String) async throws -> Login {
        struct Variables: Encodable {
            let username: String
            let pass: String
            let deviceName: String
            let type: String
            let cookie: Bool
        }
        struct Payload: Decodable { let login: Login }
        let query = """
        mutation Login($username: String!, $pass: String!, $deviceName: String!, $type: DeviceType!, $cookie: Boolean!) {
          login(username: $username, pass: $pass, deviceName: $deviceName, type: $type, cookie: $cookie) {
            token
            user { id name admin }
          }
        }
        """
        // NoExpiry + cookie:false = a long-lived token we manage ourselves.
        let vars = Variables(username: username, pass: password,
                             deviceName: deviceName, type: "NoExpiry", cookie: false)
        return try await run(query, variables: vars, as: Payload.self).login
    }

    func currentUser() async throws -> User? {
        struct Payload: Decodable { let currentUser: User? }
        let query = "query { currentUser { id name admin } }"
        return try await run(query, variables: NoVariables(), as: Payload.self).currentUser
    }

    // MARK: Pull

    func timeSpanChanges(since: Date, afterId: Int) async throws -> RemoteTimeSpanChanges {
        struct Variables: Encodable { let since: TraggoTime; let afterId: Int }
        struct WireDeletion: Decodable { let id: Int; let deletedAt: TraggoTime }
        struct WireChanges: Decodable {
            let timeSpans: [WireTimeSpan]
            let deleted: [WireDeletion]
            let hasMore: Bool
            let now: TraggoTime
        }
        struct Payload: Decodable { let timeSpanChanges: WireChanges }
        let query = """
        query Changes($since: Time!, $afterId: Int!) {
          timeSpanChanges(since: $since, afterId: $afterId) {
            timeSpans { id start end note labels { key value } updatedAt }
            deleted { id deletedAt }
            hasMore
            now
          }
        }
        """
        let changes = try await run(query,
                                    variables: Variables(since: TraggoTime(since), afterId: afterId),
                                    as: Payload.self).timeSpanChanges
        return RemoteTimeSpanChanges(
            timeSpans: changes.timeSpans.map(\.remote),
            deleted: changes.deleted.map { RemoteDeletion(id: $0.id, deletedAt: $0.deletedAt.date) },
            hasMore: changes.hasMore,
            now: changes.now.date)
    }

    func labelDefinitions() async throws -> [RemoteLabelDefinition] {
        struct Payload: Decodable { let labelDefinitions: [WireLabelDefinition]? }
        let query = """
        query { labelDefinitions { key color updatedAt valueColors { value color updatedAt } } }
        """
        return try await run(query, variables: NoVariables(), as: Payload.self)
            .labelDefinitions.map { $0.map(\.remote) } ?? []
    }

    func labelSets() async throws -> [RemoteLabelSet] {
        struct Payload: Decodable { let labelSets: [WireLabelSet]? }
        let query = """
        query { labelSets { id name symbolName updatedAt labels { key value } quickLabels { key value } } }
        """
        return try await run(query, variables: NoVariables(), as: Payload.self)
            .labelSets.map { $0.map(\.remote) } ?? []
    }

    func userPreferences() async throws -> RemotePreferences {
        struct WirePreferences: Decodable {
            let colorByValue: Bool
            let menuLabelSetLimit: Int
            let updatedAt: TraggoTime
        }
        struct Payload: Decodable { let userPreferences: WirePreferences }
        let query = "query { userPreferences { colorByValue menuLabelSetLimit updatedAt } }"
        let preferences = try await run(query, variables: NoVariables(), as: Payload.self)
            .userPreferences
        return RemotePreferences(colorByValue: preferences.colorByValue,
                                 menuLabelSetLimit: preferences.menuLabelSetLimit,
                                 updatedAt: preferences.updatedAt.date)
    }

    // MARK: Push — timespans

    func createTimeSpan(start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> Int {
        struct Variables: Encodable {
            let start: TraggoTime
            let end: TraggoTime?
            let labels: [WireLabel]
            let note: String
        }
        struct Created: Decodable { let id: Int }
        struct Payload: Decodable { let createTimeSpan: Created }
        let query = """
        mutation Create($start: Time!, $end: Time, $labels: [InputLabel!], $note: String!) {
          createTimeSpan(start: $start, end: $end, labels: $labels, note: $note) { id }
        }
        """
        let vars = Variables(start: TraggoTime(start), end: end.map(TraggoTime.init),
                             labels: labels.map(WireLabel.init), note: note)
        return try await run(query, variables: vars, as: Payload.self).createTimeSpan.id
    }

    func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws {
        struct Variables: Encodable {
            let id: Int
            let start: TraggoTime
            let end: TraggoTime?
            let labels: [WireLabel]
            let note: String
        }
        struct Updated: Decodable { let id: Int }
        struct Payload: Decodable { let updateTimeSpan: Updated }
        let query = """
        mutation Update($id: Int!, $start: Time!, $end: Time, $labels: [InputLabel!], $note: String!) {
          updateTimeSpan(id: $id, start: $start, end: $end, labels: $labels, note: $note) { id }
        }
        """
        let vars = Variables(id: id, start: TraggoTime(start), end: end.map(TraggoTime.init),
                             labels: labels.map(WireLabel.init), note: note)
        _ = try await run(query, variables: vars, as: Payload.self)
    }

    func removeTimeSpan(id: Int) async throws {
        struct Variables: Encodable { let id: Int }
        struct Removed: Decodable { let id: Int }
        struct Payload: Decodable { let removeTimeSpan: Removed? }
        let query = "mutation Remove($id: Int!) { removeTimeSpan(id: $id) { id } }"
        _ = try await run(query, variables: Variables(id: id), as: Payload.self)
    }

    // MARK: Push — label definitions and value colors

    func createLabelDefinition(key: String, color: String) async throws {
        struct Variables: Encodable { let key: String; let color: String }
        struct Definition: Decodable { let key: String }
        struct Payload: Decodable { let createLabelDefinition: Definition? }
        let query = """
        mutation CreateDefinition($key: String!, $color: String!) {
          createLabelDefinition(key: $key, color: $color) { key }
        }
        """
        _ = try await run(query, variables: Variables(key: key, color: color), as: Payload.self)
    }

    func updateLabelDefinition(key: String, color: String) async throws {
        struct Variables: Encodable { let key: String; let color: String }
        struct Definition: Decodable { let key: String }
        struct Payload: Decodable { let updateLabelDefinition: Definition? }
        let query = """
        mutation UpdateDefinition($key: String!, $color: String!) {
          updateLabelDefinition(key: $key, color: $color) { key }
        }
        """
        _ = try await run(query, variables: Variables(key: key, color: color), as: Payload.self)
    }

    func setLabelValueColor(key: String, value: String, color: String) async throws {
        struct Variables: Encodable { let key: String; let value: String; let color: String }
        struct Definition: Decodable { let key: String }
        struct Payload: Decodable { let setLabelValueColor: Definition? }
        let query = """
        mutation SetValueColor($key: String!, $value: String!, $color: String!) {
          setLabelValueColor(key: $key, value: $value, color: $color) { key }
        }
        """
        _ = try await run(query, variables: Variables(key: key, value: value, color: color),
                          as: Payload.self)
    }

    func clearLabelValueColor(key: String, value: String) async throws {
        struct Variables: Encodable { let key: String; let value: String }
        struct Definition: Decodable { let key: String }
        struct Payload: Decodable { let clearLabelValueColor: Definition? }
        let query = """
        mutation ClearValueColor($key: String!, $value: String!) {
          clearLabelValueColor(key: $key, value: $value) { key }
        }
        """
        _ = try await run(query, variables: Variables(key: key, value: value), as: Payload.self)
    }

    // MARK: Push — label sets

    // Quick labels are always sent, empty included: this client owns the
    // full list, and on the wire an *absent* `quickLabels` means "leave
    // them alone" (the pre-#92 client compat path) while an empty list
    // clears them — see api-v1.md.

    func createLabelSet(name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws -> Int {
        struct Variables: Encodable {
            let name: String
            let symbolName: String
            let labels: [WireLabel]
            let quickLabels: [WireLabel]
            let position: Int
        }
        struct Created: Decodable { let id: Int }
        struct Payload: Decodable { let createLabelSet: Created }
        let query = """
        mutation CreateSet($name: String!, $symbolName: String!, $labels: [InputLabel!]!, $quickLabels: [InputLabel!], $position: Int) {
          createLabelSet(name: $name, symbolName: $symbolName, labels: $labels, quickLabels: $quickLabels, position: $position) { id }
        }
        """
        let vars = Variables(name: name, symbolName: symbolName,
                             labels: labels.map(WireLabel.init),
                             quickLabels: quickLabels.map(WireLabel.init),
                             position: position)
        return try await run(query, variables: vars, as: Payload.self).createLabelSet.id
    }

    func updateLabelSet(id: Int, name: String, symbolName: String, labels: [SpanLabel],
                        quickLabels: [SpanLabel], position: Int) async throws {
        struct Variables: Encodable {
            let id: Int
            let name: String
            let symbolName: String
            let labels: [WireLabel]
            let quickLabels: [WireLabel]
            let position: Int
        }
        struct Updated: Decodable { let id: Int }
        struct Payload: Decodable { let updateLabelSet: Updated }
        let query = """
        mutation UpdateSet($id: Int!, $name: String!, $symbolName: String!, $labels: [InputLabel!]!, $quickLabels: [InputLabel!], $position: Int) {
          updateLabelSet(id: $id, name: $name, symbolName: $symbolName, labels: $labels, quickLabels: $quickLabels, position: $position) { id }
        }
        """
        let vars = Variables(id: id, name: name, symbolName: symbolName,
                             labels: labels.map(WireLabel.init),
                             quickLabels: quickLabels.map(WireLabel.init),
                             position: position)
        _ = try await run(query, variables: vars, as: Payload.self)
    }

    func removeLabelSet(id: Int) async throws {
        struct Variables: Encodable { let id: Int }
        struct Removed: Decodable { let id: Int }
        struct Payload: Decodable { let removeLabelSet: Removed? }
        let query = "mutation RemoveSet($id: Int!) { removeLabelSet(id: $id) { id } }"
        _ = try await run(query, variables: Variables(id: id), as: Payload.self)
    }

    // MARK: Push — preferences

    func setUserPreferences(colorByValue: Bool, menuLabelSetLimit: Int) async throws {
        struct Preferences: Encodable { let colorByValue: Bool; let menuLabelSetLimit: Int }
        struct Variables: Encodable { let preferences: Preferences }
        struct Saved: Decodable { let colorByValue: Bool }
        struct Payload: Decodable { let setUserPreferences: Saved }
        let query = """
        mutation SetPreferences($preferences: InputUserPreferences!) {
          setUserPreferences(preferences: $preferences) { colorByValue }
        }
        """
        let vars = Variables(preferences: Preferences(colorByValue: colorByValue,
                                                      menuLabelSetLimit: menuLabelSetLimit))
        _ = try await run(query, variables: vars, as: Payload.self)
    }
}
