import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The sync engine against the in-process `FakeSyncServer`: push of dirty
/// records, pull-merge, last-writer-wins in both directions, tombstone
/// propagation both ways, checkpoint advance, the offline queue, and — the
/// origin-mapping lesson — no duplicate creation on re-sync.
@MainActor
@Suite struct SyncEngineTests {

    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    /// A connected store + fake server + engine. The fake's clock starts an
    /// hour in the past so that local edits (stamped with the real wall
    /// clock) are newer than server records unless a test moves the clock —
    /// and on a whole second, like the real server's sync timestamps, so
    /// checkpoints survive the store's millisecond precision exactly.
    private func makeConnected() throws -> (LocalBackend, FakeSyncServer, SyncEngine) {
        let store = try LocalBackend(DatabaseQueue())
        let server = FakeSyncServer()
        server.now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        try store.connectSyncServer(url: "https://sync.test",
                                    user: User(id: 1, name: "steven", admin: false))
        let engine = SyncEngine(store: store, server: server)
        return (store, server, engine)
    }

    private func sync(_ engine: SyncEngine) async throws {
        _ = try await engine.performSync()
    }

    /// All spans in the store (finished + running).
    private func allSpans(_ store: LocalBackend) async throws -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var token: PageToken?
        repeat {
            let page = try await store.timeSpans(from: .distantPast,
                                                 to: .distantFuture, page: token)
            spans += page.timeSpans
            token = page.nextPage
        } while token != nil
        return spans + (try await store.timers())
    }

    // MARK: Push

    @Test func firstSyncPushesEverythingLocal() async throws {
        let (store, server, engine) = try makeConnected()
        try await store.createLabelDefinition(key: "proj", color: "#112233")
        try store.saveValueColors([ValueColorKey.join("proj", "sync"): "#445566"])
        try store.saveTagSets([TagSet(name: "Deep Work",
                                      tags: [TagRow(key: "proj", value: "sync")],
                                      symbolName: "brain")])
        _ = try await store.startTimeSpan(start: date(1_000),
                                          labels: [SpanLabel(key: "proj", value: "sync")],
                                          note: "running")
        let finished = try await store.startTimeSpan(start: date(2_000), labels: [], note: "")
        _ = try await store.updateTimeSpan(id: finished.id, start: date(2_000),
                                           end: date(3_000), labels: [], note: "done")

        try await sync(engine)

        #expect(server.spans.count == 2)
        #expect(server.definitions["proj"]?.color == "#112233")
        #expect(server.definitions["proj"]?.valueColors.map(\.color) == ["#445566"])
        #expect(server.orderedSetNames == ["Deep Work"])
        let serverNotes = Set(server.spans.values.map(\.note))
        #expect(serverNotes == ["running", "done"])
        // Everything pushed is clean now.
        #expect(try await store.pendingSpanPushes().isEmpty)
    }

    @Test func reSyncCreatesNoDuplicates() async throws {
        let (store, server, engine) = try makeConnected()
        _ = try await store.startTimeSpan(start: date(1_000), labels: [], note: "one")
        try store.saveTagSets([TagSet(name: "Set")])

        try await sync(engine)
        let spanCount = server.spans.count
        let setCount = server.sets.count

        try await sync(engine)
        try await sync(engine)

        #expect(server.spans.count == spanCount)
        #expect(server.sets.count == setCount)
        #expect(try await allSpans(store).count == 1)
        #expect(try store.loadTagSets().count == 1)
    }

    // MARK: Pull

    @Test func pullBringsServerDataIntoEmptyStore() async throws {
        let (store, server, engine) = try makeConnected()
        // A fresh store seeds the sample tag sets; empty it so this test
        // sees exactly what the pull brings.
        try store.saveTagSets([])
        server.seedDefinition(key: "type", color: "#abcdef",
                              valueColors: [("meeting", "#222222")])
        server.seedSet(name: "Meeting", symbol: "person.2",
                       labels: [SpanLabel(key: "type", value: "meeting")])
        _ = server.seedSpan(start: date(1_000), end: date(2_000), note: "from server",
                            labels: [SpanLabel(key: "type", value: "meeting")])
        _ = server.seedSpan(start: date(5_000), end: nil, note: "still running")

        try await sync(engine)

        let spans = try await allSpans(store)
        #expect(spans.count == 2)
        #expect(spans.contains { $0.note == "from server" && $0.end != nil })
        #expect(spans.contains { $0.note == "still running" && $0.isRunning })
        #expect(try await store.labelDefinitions() == [LabelDefinition(key: "type", color: "#abcdef")])
        #expect(try store.loadValueColors() == [ValueColorKey.join("type", "meeting"): "#222222"])
        let sets = try store.loadTagSets()
        #expect(sets.map(\.name) == ["Meeting"])
        #expect(sets.first?.symbolName == "person.2")
        // Pulled data is clean — nothing echoes back up.
        #expect(try await store.pendingSpanPushes().isEmpty)
    }

    @Test func pulledSpansDontDuplicateOnReSync() async throws {
        let (store, server, engine) = try makeConnected()
        _ = server.seedSpan(start: date(1_000), end: date(2_000), note: "once")

        try await sync(engine)
        try await sync(engine)

        #expect(try await allSpans(store).count == 1)
    }

    @Test func checkpointAdvances() async throws {
        let (store, server, engine) = try makeConnected()
        let seedTime = server.now
        let seededId = server.seedSpan(start: date(1_000), end: date(2_000))
        try await sync(engine)
        let callsAfterFirst = server.changesCalls.count

        // Nothing new: the next pull starts at the last (updatedAt, id) and
        // returns nothing.
        try await sync(engine)
        #expect(server.changesCalls.count > callsAfterFirst)
        #expect(server.changesCalls.last!.since == seedTime)
        #expect(server.changesCalls.last!.afterId == seededId)
        #expect(try await allSpans(store).count == 1)

        // A later server write is picked up from the checkpoint.
        server.now = Date()
        _ = server.seedSpan(start: date(9_000), end: date(9_500), note: "new")
        try await sync(engine)
        #expect(try await allSpans(store).count == 2)
    }

    @Test func pullPagesThroughLargeFeeds() async throws {
        let (store, server, engine) = try makeConnected()
        server.pageLimit = 2
        for index in 0..<5 {
            _ = server.seedSpan(start: date(index * 100), end: date(index * 100 + 50))
        }
        try await sync(engine)
        #expect(try await allSpans(store).count == 5)
    }

    // MARK: Last-writer-wins

    @Test func lwwLocalEditBeatsOlderServerEdit() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "original")
        try await sync(engine)
        let serverId = server.spans.keys.first!

        // The server copy changes at its (hour-old) clock; the local edit is
        // now — local wins.
        try await server.updateTimeSpan(id: serverId, start: date(1_000), end: nil,
                                        labels: [], note: "server edit")
        _ = try await store.updateTimeSpan(id: span.id, start: date(1_000), end: nil,
                                           labels: [], note: "local edit")

        try await sync(engine)
        #expect(server.spans[serverId]?.note == "local edit")
        let local = try await allSpans(store)
        #expect(local.map(\.note) == ["local edit"])
    }

    @Test func lwwNewerServerEditBeatsLocalEdit() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "original")
        try await sync(engine)
        let serverId = server.spans.keys.first!

        // Local edit now; server edit an hour in the future — server wins.
        _ = try await store.updateTimeSpan(id: span.id, start: date(1_000), end: nil,
                                           labels: [], note: "local edit")
        server.now = Date().addingTimeInterval(3600)
        try await server.updateTimeSpan(id: serverId, start: date(1_000), end: nil,
                                        labels: [], note: "server edit")

        try await sync(engine)
        let local = try await allSpans(store)
        #expect(local.map(\.note) == ["server edit"])
        #expect(server.spans[serverId]?.note == "server edit")
        #expect(try await store.pendingSpanPushes().isEmpty)
    }

    @Test func lwwAppliesToDefinitionsAndValueColors() async throws {
        let (store, server, engine) = try makeConnected()
        try await store.createLabelDefinition(key: "proj", color: "#111111")
        try await sync(engine)

        // Older server recolor loses to a fresh local recolor.
        try await server.updateLabelDefinition(key: "proj", color: "#222222")
        try await store.updateLabelDefinition(key: "proj", color: "#333333")
        try await sync(engine)
        #expect(server.definitions["proj"]?.color == "#333333")

        // A future-dated server recolor wins over a local one.
        server.now = Date().addingTimeInterval(3600)
        try await server.updateLabelDefinition(key: "proj", color: "#444444")
        try await store.updateLabelDefinition(key: "proj", color: "#555555")
        try await sync(engine)
        #expect(try await store.labelDefinitions().first?.color == "#444444")
    }

    // MARK: Deletions

    @Test func localDeletionPropagatesToServer() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "doomed")
        try await sync(engine)
        #expect(server.spans.count == 1)

        try await store.removeTimeSpan(id: span.id)
        try await sync(engine)
        #expect(server.spans.isEmpty)
        #expect(try await store.spanTombstones().isEmpty)   // consumed
    }

    @Test func serverDeletionPropagatesLocally() async throws {
        let (store, server, engine) = try makeConnected()
        _ = try await store.startTimeSpan(start: date(1_000), labels: [], note: "doomed")
        try await sync(engine)
        let serverId = server.spans.keys.first!

        server.now = Date()
        try await server.removeTimeSpan(id: serverId)
        try await sync(engine)
        #expect(try await allSpans(store).isEmpty)
    }

    @Test func deletingNeverSyncedSpanLeavesNoTombstone() async throws {
        let (store, _, _) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "")
        try await store.removeTimeSpan(id: span.id)
        #expect(try await store.spanTombstones().isEmpty)
    }

    @Test func localEditNewerThanServerDeletionRecreates() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "keep me")
        try await sync(engine)
        let serverId = server.spans.keys.first!

        // Deleted on the server (hour-old clock), then edited here (now):
        // the edit wins and the span returns under a fresh server id.
        try await server.removeTimeSpan(id: serverId)
        _ = try await store.updateTimeSpan(id: span.id, start: date(1_000), end: nil,
                                           labels: [], note: "edited after delete")

        try await sync(engine)
        #expect(server.spans.count == 1)
        #expect(server.spans.values.first?.note == "edited after delete")
        #expect(server.spans.keys.first != serverId)
        #expect(try await allSpans(store).count == 1)
    }

    @Test func serverEditNewerThanLocalDeletionResurrects() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "original")
        try await sync(engine)
        let serverId = server.spans.keys.first!

        // Deleted here (now), then edited on the server later: the edit wins
        // and the span comes back.
        try await store.removeTimeSpan(id: span.id)
        server.now = Date().addingTimeInterval(3600)
        try await server.updateTimeSpan(id: serverId, start: date(1_000), end: nil,
                                        labels: [], note: "revived elsewhere")

        try await sync(engine)
        let local = try await allSpans(store)
        #expect(local.map(\.note) == ["revived elsewhere"])
        #expect(server.spans.count == 1)
    }

    @Test func labelSetDeletionPropagatesBothWays() async throws {
        let (store, server, engine) = try makeConnected()
        try store.saveTagSets([TagSet(name: "A"), TagSet(name: "B")])
        try await sync(engine)
        #expect(server.orderedSetNames == ["A", "B"])

        // Local deletion → server.
        var sets = try store.loadTagSets()
        sets.removeAll { $0.name == "A" }
        try store.saveTagSets(sets)
        try await sync(engine)
        #expect(server.orderedSetNames == ["B"])

        // Server deletion (another device) → local mirror.
        let remaining = server.sets.keys.first!
        try await server.removeLabelSet(id: remaining)
        try await sync(engine)
        #expect(try store.loadTagSets().isEmpty)
    }

    @Test func cardColorSurvivesRemoteLabelSetUpdate() async throws {
        let (store, server, engine) = try makeConnected()
        try store.saveTagSets([TagSet(name: "Gaming", colorHex: "#aabbcc")])
        try await sync(engine)

        // Renamed on the server (another device) later: the merge takes the
        // synced fields but must leave the local-only card color alone.
        let serverId = server.sets.keys.first!
        server.now = Date().addingTimeInterval(3600)
        try await server.updateLabelSet(id: serverId, name: "Games",
                                        symbolName: "gamecontroller",
                                        labels: [], quickLabels: [], position: 0)
        try await sync(engine)
        let merged = try store.loadTagSets()
        #expect(merged.map(\.name) == ["Games"])
        #expect(merged.first?.colorHex == "#aabbcc")
    }

    // MARK: Quick labels (#92) — they ride the label-set snapshot

    @Test func quickLabelsPushWithTheirSet() async throws {
        let (store, server, engine) = try makeConnected()
        let set = TagSet(name: "Deep Work", symbolName: "brain")
        try store.saveTagSets([set])
        try store.saveQuickLabels([set.id.uuidString: [TagRow(key: "type", value: "review"),
                                                       TagRow(key: "type", value: "debugging")]])
        try await sync(engine)
        #expect(server.sets.values.first?.quickLabels
            == [SpanLabel(key: "type", value: "review"),
                SpanLabel(key: "type", value: "debugging")])

        // A quick-label edit alone dirties the set and pushes as an update.
        try store.saveQuickLabels([set.id.uuidString: [TagRow(key: "type", value: "review")]])
        try await sync(engine)
        #expect(server.sets.count == 1)
        #expect(server.sets.values.first?.quickLabels == [SpanLabel(key: "type", value: "review")])
    }

    @Test func quickLabelsPullWithTheirSet() async throws {
        let (store, server, engine) = try makeConnected()
        try store.saveTagSets([])
        let serverId = server.seedSet(name: "Deep Work", symbol: "brain",
                                      quickLabels: [SpanLabel(key: "type", value: "review")])

        try await sync(engine)
        let localId = try #require(try store.loadTagSets().first?.id.uuidString)
        #expect(try store.loadQuickLabels()[localId]?.map(\.value) == ["review"])

        // Edited elsewhere later: the newer server list replaces the local
        // one — including a clear.
        server.now = Date().addingTimeInterval(3600)
        try await server.updateLabelSet(id: serverId, name: "Deep Work",
                                        symbolName: "brain", labels: [],
                                        quickLabels: [], position: 0)
        try await sync(engine)
        #expect(try store.loadQuickLabels()[localId] == nil)
    }

    @Test func newerLocalQuickLabelsWinOverRemoteSet() async throws {
        let (store, server, engine) = try makeConnected()
        let set = TagSet(name: "Deep Work", symbolName: "brain")
        try store.saveTagSets([set])
        try await sync(engine)

        // Concurrent edits: the server copy first (older), then the local
        // quick-label edit (newer wall clock). Local wins and pushes.
        let serverId = server.sets.keys.first!
        try await server.updateLabelSet(id: serverId, name: "Deep Work",
                                        symbolName: "brain", labels: [],
                                        quickLabels: [SpanLabel(key: "type", value: "stale")],
                                        position: 0)
        try store.saveQuickLabels([set.id.uuidString: [TagRow(key: "type", value: "fresh")]])
        try await sync(engine)
        #expect(server.sets.values.first?.quickLabels == [SpanLabel(key: "type", value: "fresh")])
        #expect(try store.loadQuickLabels()[set.id.uuidString]?.map(\.value) == ["fresh"])
    }

    // MARK: Offline queue

    @Test func offlineEditsQueueAndPushOnReconnect() async throws {
        let (store, server, engine) = try makeConnected()
        let span = try await store.startTimeSpan(start: date(1_000), labels: [], note: "v1")
        try await sync(engine)

        server.offline = true
        _ = try await store.updateTimeSpan(id: span.id, start: date(1_000), end: date(2_000),
                                           labels: [], note: "offline edit")
        let offlineSpan = try await store.startTimeSpan(start: date(3_000), labels: [], note: "born offline")
        try await store.removeTimeSpan(id: offlineSpan.id)   // and deleted offline
        await engine.syncNow()
        guard case .error = engine.status else {
            Issue.record("expected an error status while offline")
            return
        }
        #expect(server.spans.values.first?.note == "v1")     // nothing reached it

        server.offline = false
        try await sync(engine)
        #expect(server.spans.count == 1)
        #expect(server.spans.values.first?.note == "offline edit")
        #expect(try await store.pendingSpanPushes().isEmpty)
    }

    // MARK: Definitions created on demand

    @Test func pushingSpanWithUndefinedKeyCreatesDefinition() async throws {
        let (store, server, engine) = try makeConnected()
        // A span whose label key has no definition anywhere (possible for
        // imported history).
        _ = try await store.startTimeSpan(
            start: date(1_000),
            labels: [SpanLabel(key: "orphan", value: "x")], note: "")
        try await store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM label_definition")
        }

        try await sync(engine)
        #expect(server.definitions["orphan"] != nil)
        #expect(server.spans.count == 1)
        #expect(try await store.definitionKeys().contains("orphan"))
    }

    // MARK: Label set order

    @Test func launcherOrderSyncs() async throws {
        let (store, server, engine) = try makeConnected()
        try store.saveTagSets([TagSet(name: "A"), TagSet(name: "B"), TagSet(name: "C")])
        try await sync(engine)
        #expect(server.orderedSetNames == ["A", "B", "C"])

        // Reorder locally; positions travel with the update pushes.
        var sets = try store.loadTagSets()
        sets.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        try store.saveTagSets(sets)
        try await sync(engine)
        #expect(server.orderedSetNames == ["C", "A", "B"])
    }

    // MARK: Preferences

    @Test func preferencesPushWhenNeverSetOnServer() async throws {
        let (store, server, engine) = try makeConnected()
        var local = (colorByValue: false, menuLabelSetLimit: 9)
        engine.readPreferences = { local }
        engine.applyPreferences = { local = ($0, $1) }
        try store.markPreferencesDirty()

        try await sync(engine)
        #expect(server.preferencesEverSet)
        #expect(server.preferences.colorByValue == false)
        #expect(server.preferences.menuLabelSetLimit == 9)
    }

    @Test func preferencesInheritFromServerOnConnect() async throws {
        let (store, server, engine) = try makeConnected()
        // Another device set preferences; this store never touched its own
        // (prefs_modified_at is nil) — the server's win.
        try await server.setUserPreferences(colorByValue: false, menuLabelSetLimit: 2)
        var local = (colorByValue: true, menuLabelSetLimit: 5)
        engine.readPreferences = { local }
        engine.applyPreferences = { local = ($0, $1) }
        _ = store   // connection made in makeConnected

        try await sync(engine)
        #expect(local.colorByValue == false)
        #expect(local.menuLabelSetLimit == 2)
    }

    @Test func newerLocalPreferenceEditBeatsServer() async throws {
        let (store, server, engine) = try makeConnected()
        try await server.setUserPreferences(colorByValue: false, menuLabelSetLimit: 2)
        var local = (colorByValue: true, menuLabelSetLimit: 7)
        engine.readPreferences = { local }
        engine.applyPreferences = { local = ($0, $1) }
        try store.markPreferencesDirty()   // stamped now — newer than the server

        try await sync(engine)
        #expect(server.preferences.menuLabelSetLimit == 7)
        #expect(local.menuLabelSetLimit == 7)
    }

    // MARK: Reconnect semantics

    @Test func reconnectToSameServerResumesWithoutDuplicates() async throws {
        let (store, server, engine) = try makeConnected()
        _ = try await store.startTimeSpan(start: date(1_000), labels: [], note: "kept")
        try await sync(engine)
        #expect(server.spans.count == 1)

        try store.disconnectSyncServer()
        #expect(try store.syncServer()?.active == false)
        try store.connectSyncServer(url: "https://sync.test",
                                    user: User(id: 1, name: "steven", admin: false))
        try await sync(engine)
        #expect(server.spans.count == 1)
        #expect(try await allSpans(store).count == 1)
    }

    @Test func connectToDifferentServerStartsOver() async throws {
        let (store, _, engine) = try makeConnected()
        _ = try await store.startTimeSpan(start: date(1_000), labels: [], note: "mine")
        try await sync(engine)

        // A different URL invalidates mappings; everything goes dirty and
        // pushes fresh to the new server.
        try store.connectSyncServer(url: "https://other.test",
                                    user: User(id: 2, name: "steven", admin: false))
        let newServer = FakeSyncServer()
        newServer.now = Date().addingTimeInterval(-3600)
        let newEngine = SyncEngine(store: store, server: newServer)
        _ = try await newEngine.performSync()
        #expect(newServer.spans.count == 1)
        #expect(try await allSpans(store).count == 1)
    }
}
