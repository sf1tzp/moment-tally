import Foundation
import MomentTallyCore

/// A thin GraphQL client for Traggo, and the `Backend` implementation the app
/// ships with. There are only ~10 operations, so a hand-rolled client over
/// URLSession is simpler than pulling in Apollo. Wire DTOs (TraggoModels.swift)
/// are mapped to the domain types here, at the boundary.
///
/// Auth: Traggo expects `Authorization: traggo <token>` (literally the word
/// "traggo", not "Bearer"). The token is a "device" token minted by `login` —
/// a traggo concern, which is why `login` is not part of `Backend`.
package struct TraggoClient: Backend {
    package var baseURL: URL
    package var token: String?

    package init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    package struct APIError: LocalizedError {
        package let message: String
        package var errorDescription: String? { message }

        package init(message: String) {
            self.message = message
        }
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

    /// Placeholder for operations that take no variables.
    package struct NoVariables: Encodable {}

    // MARK: Core request

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
            throw APIError(message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody<Payload>.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            throw APIError(message: errors.map(\.message).joined(separator: "\n"))
        }
        guard let payload = decoded.data else {
            throw APIError(message: "Empty response")
        }
        return payload
    }

    // MARK: Session (traggo-specific, not part of Backend)

    package func login(username: String, password: String, deviceName: String) async throws -> Login {
        struct Variables: Encodable {
            let username: String
            let pass: String
            let deviceName: String
            let type: String   // DeviceType enum, serialized as its name
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
        // NoExpiry (365d) + cookie:false = a long-lived token we manage ourselves.
        let vars = Variables(username: username, pass: password,
                             deviceName: deviceName, type: "NoExpiry", cookie: false)
        return try await run(query, variables: vars, as: Payload.self).login
    }

    // MARK: Backend operations

    /// Validates the stored token and returns the logged-in user (nil if the
    /// token is no longer valid).
    package func currentUser() async throws -> User? {
        struct Payload: Decodable { let currentUser: User? }
        let query = "query { currentUser { id name admin } }"
        return try await run(query, variables: NoVariables(), as: Payload.self).currentUser
    }

    /// All currently-running timespans (end == null), newest first.
    package func timers() async throws -> [TimeSpan] {
        struct Payload: Decodable { let timers: [TraggoTimeSpan]? }
        let query = """
        query { timers { id start end note tags { key value } } }
        """
        return try await run(query, variables: NoVariables(), as: Payload.self)
            .timers.map { $0.map(\.domain) } ?? []
    }

    /// Existing tag definitions (the reusable keys, with colors).
    package func labelDefinitions() async throws -> [LabelDefinition] {
        struct Payload: Decodable { let tags: [TagDefinition]? }
        let query = "query { tags { key color } }"
        return try await run(query, variables: NoVariables(), as: Payload.self)
            .tags.map { $0.map(\.domain) } ?? []
    }

    /// Create a tag definition. Required before a key can be attached to a
    /// timespan (the server rejects unknown keys).
    package func createLabelDefinition(key: String, color: String) async throws {
        struct Variables: Encodable { let key: String; let color: String }
        struct Payload: Decodable { let createTag: TagDefinition? }
        // Select key AND color: the payload decodes as TagDefinition, which
        // requires both (selecting only `key` makes every createTag "fail").
        let query = """
        mutation CreateTag($key: String!, $color: String!) {
          createTag(key: $key, color: $color) { key color }
        }
        """
        _ = try await run(query, variables: Variables(key: key, color: color), as: Payload.self)
    }

    /// Change the color of an existing tag key. Traggo stores color per key,
    /// so this affects that key everywhere it's used.
    package func updateLabelDefinition(key: String, color: String) async throws {
        struct Variables: Encodable { let key: String; let color: String }
        struct Payload: Decodable { let updateTag: TagDefinition? }
        let query = """
        mutation UpdateTag($key: String!, $color: String!) {
          updateTag(key: $key, color: $color) { key color }
        }
        """
        _ = try await run(query, variables: Variables(key: key, color: color), as: Payload.self)
    }

    /// Start a running timespan (no end time).
    package func startTimeSpan(start: Date, labels: [SpanLabel], note: String) async throws -> TimeSpan {
        struct Variables: Encodable {
            let start: TraggoTime
            let tags: [TimeSpanTag]
            let note: String
        }
        struct Payload: Decodable { let createTimeSpan: TraggoTimeSpan }
        let query = """
        mutation Start($start: Time!, $tags: [InputTimeSpanTag!], $note: String!) {
          createTimeSpan(start: $start, tags: $tags, note: $note) {
            id start end note tags { key value }
          }
        }
        """
        let vars = Variables(start: TraggoTime(start),
                             tags: labels.map(TimeSpanTag.init), note: note)
        return try await run(query, variables: vars, as: Payload.self).createTimeSpan.domain
    }

    /// Update a timespan in place. `start` and `note` are required by the schema,
    /// so callers pass the current values for anything they're not changing.
    /// A nil `end` leaves the timespan running.
    package func updateTimeSpan(id: Int, start: Date, end: Date?, labels: [SpanLabel], note: String) async throws -> TimeSpan {
        struct Variables: Encodable {
            let id: Int
            let start: TraggoTime
            let end: TraggoTime?
            let tags: [TimeSpanTag]
            let note: String
        }
        struct Payload: Decodable { let updateTimeSpan: TraggoTimeSpan }
        let query = """
        mutation Update($id: Int!, $start: Time!, $end: Time, $tags: [InputTimeSpanTag!], $note: String!) {
          updateTimeSpan(id: $id, start: $start, end: $end, tags: $tags, note: $note) {
            id start end note tags { key value }
          }
        }
        """
        let vars = Variables(id: id, start: TraggoTime(start),
                             end: end.map(TraggoTime.init),
                             tags: labels.map(TimeSpanTag.init), note: note)
        return try await run(query, variables: vars, as: Payload.self).updateTimeSpan.domain
    }

    /// One page of finished timespans overlapping [from, to], newest first.
    /// Running timespans (end == null) are excluded server-side; merge in
    /// `timers()` for a complete picture.
    package func timeSpans(from: Date, to: Date, page: PageToken?) async throws -> TimeSpanPage {
        // On the first page startId must be *absent* so the server pins the walk
        // to the current newest id (an explicit 0 would filter to nothing).
        // The server caps pageSize at 100.
        struct InputCursor: Encodable { let offset: Int; let startId: Int?; let pageSize: Int }
        struct Variables: Encodable {
            let fromInclusive: TraggoTime
            let toInclusive: TraggoTime
            let cursor: InputCursor
        }
        struct Payload: Decodable { let timeSpans: PagedTimeSpans }
        let query = """
        query TimeSpans($fromInclusive: Time!, $toInclusive: Time!, $cursor: InputCursor) {
          timeSpans(fromInclusive: $fromInclusive, toInclusive: $toInclusive, cursor: $cursor) {
            timeSpans { id start end note tags { key value } }
            cursor { hasMore offset startId pageSize }
          }
        }
        """
        let input = page.flatMap(Cursor.init)
            .map { InputCursor(offset: $0.offset, startId: $0.startId, pageSize: $0.pageSize) }
            ?? InputCursor(offset: 0, startId: nil, pageSize: 100)
        let vars = Variables(fromInclusive: TraggoTime(from), toInclusive: TraggoTime(to), cursor: input)
        let paged = try await run(query, variables: vars, as: Payload.self).timeSpans
        return TimeSpanPage(timeSpans: paged.timeSpans.map(\.domain),
                            nextPage: paged.cursor.pageToken)
    }

    /// Delete a timespan by id.
    package func removeTimeSpan(id: Int) async throws {
        struct Variables: Encodable { let id: Int }
        // Decode only what the mutation selects — decoding a full TimeSpan here
        // throws keyNotFound and masks a successful delete as an error.
        struct Deleted: Decodable { let id: Int }
        struct Payload: Decodable { let removeTimeSpan: Deleted? }
        let query = """
        mutation Remove($id: Int!) {
          removeTimeSpan(id: $id) { id }
        }
        """
        _ = try await run(query, variables: Variables(id: id), as: Payload.self)
    }

    /// Stop a running timespan by id.
    package func stopTimeSpan(id: Int, end: Date) async throws -> TimeSpan {
        struct Variables: Encodable { let id: Int; let end: TraggoTime }
        struct Payload: Decodable { let stopTimeSpan: TraggoTimeSpan }
        let query = """
        mutation Stop($id: Int!, $end: Time!) {
          stopTimeSpan(id: $id, end: $end) {
            id start end note tags { key value }
          }
        }
        """
        return try await run(query, variables: Variables(id: id, end: TraggoTime(end)),
                             as: Payload.self).stopTimeSpan.domain
    }
}
