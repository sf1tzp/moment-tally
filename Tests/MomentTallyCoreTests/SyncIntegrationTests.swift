import Foundation
import GRDB
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// End-to-end against a *live* Moment Tally server: two in-memory local stores
/// ("two Macs"), each with its own device token and `SyncEngine` over the
/// real `MomentTallyClient`, converging through one real server process.
///
/// Opt-in: set `SYNC_INTEGRATION_URL` (plus `SYNC_INTEGRATION_USER` /
/// `SYNC_INTEGRATION_PASS`, default convergence/convergepass) to a running
/// server, e.g.
///
///     TRAGGO_DATABASE_DIALECT=sqlite3 TRAGGO_DATABASE_CONNECTION=/tmp/s.db \
///         ./moment-tally-server &
///     ./admin create-user -name convergence -pass convergepass
///     SYNC_INTEGRATION_URL=http://localhost:19080 swift test
///
/// The test tolerates pre-existing account data by marking everything it
/// creates with a per-run UUID and asserting only over marked records.
@MainActor
@Suite struct SyncIntegrationTests {

    private nonisolated static var url: String? {
        ProcessInfo.processInfo.environment["SYNC_INTEGRATION_URL"]
    }

    private struct Mac {
        let store: LocalBackend
        let engine: SyncEngine
    }

    /// Log a fresh device in and wire a store + engine to the live server.
    private func makeMac(name: String) async throws -> Mac {
        let base = Self.url!
        let env = ProcessInfo.processInfo.environment
        let user = env["SYNC_INTEGRATION_USER"] ?? "convergence"
        let pass = env["SYNC_INTEGRATION_PASS"] ?? "convergepass"
        var client = MomentTallyClient(baseURL: URL(string: base)!, token: nil)
        let login = try await client.login(username: user, password: pass,
                                           deviceName: "sync-integration-\(name)")
        client.token = login.token
        let store = try LocalBackend(DatabaseQueue())
        try store.connectSyncServer(url: base, user: login.user)
        return Mac(store: store, engine: SyncEngine(store: store, server: client))
    }

    private func sync(_ mac: Mac) async throws {
        _ = try await mac.engine.performSync()
    }

    /// Spans carrying this run's marker in their note.
    private func markedSpans(_ store: LocalBackend, marker: String) async throws -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var token: PageToken?
        repeat {
            let page = try await store.timeSpans(from: .distantPast,
                                                 to: .distantFuture, page: token)
            spans += page.timeSpans
            token = page.nextPage
        } while token != nil
        spans += (try await store.timers())
        return spans.filter { $0.note.contains(marker) }
    }

    @Test(.enabled(if: url != nil))
    func twoMacsConvergeThroughLiveServer() async throws {
        let marker = UUID().uuidString.prefix(8).lowercased()
        let key = "it\(marker.prefix(6))"   // a label key unique to this run

        let macA = try await makeMac(name: "a")
        let macB = try await makeMac(name: "b")

        // Mac A: a running span with a label, a tag set, and a value color.
        try await macA.store.createLabelDefinition(key: key, color: "#123456")
        try macA.store.saveValueColors([ValueColorKey.join(key, "live"): "#654321"])
        var setsA = try macA.store.loadTagSets()
        let setA = TagSet(name: "Set \(marker)",
                          tags: [TagRow(key: key, value: "live")],
                          symbolName: "bolt")
        setsA.append(setA)
        try macA.store.saveTagSets(setsA)
        var quickA = try macA.store.loadQuickLabels()
        quickA[setA.id.uuidString] = [TagRow(key: key, value: "quick")]
        try macA.store.saveQuickLabels(quickA)
        let started = try await macA.store.startTimeSpan(
            start: Date(timeIntervalSince1970: 1_753_000_000),
            labels: [SpanLabel(key: key, value: "live")],
            note: "started on A \(marker)")
        try await sync(macA)

        // Mac B: everything arrives.
        try await sync(macB)
        let arrived = try await markedSpans(macB.store, marker: marker)
        #expect(arrived.count == 1)
        #expect(arrived.first?.isRunning == true)
        #expect(arrived.first?.labels == [SpanLabel(key: key, value: "live")])
        #expect(try macB.store.loadTagSets().contains { $0.name == "Set \(marker)" })
        let setOnB = try macB.store.loadTagSets().first { $0.name == "Set \(marker)" }
        // Compare key/value pairs — TagRow equality includes its view-local id.
        #expect(try macB.store.loadQuickLabels()[setOnB?.id.uuidString ?? ""]?
            .map { ($0.key, $0.value) == (key, "quick") } == [true])
        #expect(try macB.store.loadValueColors()[ValueColorKey.join(key, "live")] == "#654321")
        #expect(try await macB.store.labelDefinitions().contains {
            $0.key == key && $0.color == "#123456"
        })

        // Mac B stops the span and edits the note; A picks both up.
        let onB = arrived.first!
        _ = try await macB.store.stopTimeSpan(id: onB.id,
                                              end: Date(timeIntervalSince1970: 1_753_003_600))
        _ = try await macB.store.updateTimeSpan(
            id: onB.id, start: onB.start,
            end: Date(timeIntervalSince1970: 1_753_003_600),
            labels: onB.labels, note: "stopped on B \(marker)")
        try await sync(macB)
        try await sync(macA)
        let backOnA = try await markedSpans(macA.store, marker: marker)
        #expect(backOnA.count == 1)
        #expect(backOnA.first?.id == started.id)   // same local row, updated
        #expect(backOnA.first?.isRunning == false)
        #expect(backOnA.first?.note == "stopped on B \(marker)")

        // Mac A recolors the key; B inherits it.
        try await macA.store.updateLabelDefinition(key: key, color: "#abcdef")
        try await sync(macA)
        try await sync(macB)
        #expect(try await macB.store.labelDefinitions().contains {
            $0.key == key && $0.color == "#abcdef"
        })

        // Mac B deletes the span; it disappears from A.
        let idOnB = try await markedSpans(macB.store, marker: marker).first!.id
        try await macB.store.removeTimeSpan(id: idOnB)
        try await sync(macB)
        try await sync(macA)
        #expect(try await markedSpans(macA.store, marker: marker).isEmpty)

        // Cleanup: drop this run's tag set + value color on A, propagate.
        try macA.store.saveTagSets(try macA.store.loadTagSets()
            .filter { $0.name != "Set \(marker)" })
        try macA.store.saveValueColors([:])
        try await sync(macA)
        try await sync(macB)
        #expect(try !macB.store.loadTagSets().contains { $0.name == "Set \(marker)" })
    }
}
