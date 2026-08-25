import Foundation
import MomentTallyCore
import Observation
import SwiftUI
import AppKit

/// The whole app's state and behaviour. `@MainActor` because everything here
/// drives the UI; `@Observable` so SwiftUI views re-render when it changes.
///
/// Storage model (#33): the local SQLite store is the *only* backend — every
/// read and write goes through it, no server required. Connecting a sync
/// server doesn't switch backends; it attaches a `SyncEngine` that
/// reconciles the same store with the server in the background, which is
/// what turns tag sets, colours, and preferences from per-Mac into per-user.
/// The old live-traggo mode is gone; `TraggoClient` survives only as the
/// importer's source.
@MainActor
@Observable
final class AppModel {
    /// True when launched in demo mode (#39). The whole session is then
    /// sandboxed: the local store is a regenerated `demo.sqlite`, `defaults`
    /// is a wiped scratch suite, the keychain token is ignored, and Settings
    /// hides the storage picker — so nothing done in a demo can touch real
    /// data or preferences.
    let isDemo: Bool

    /// Where every settings read/write goes: the standard domain normally, a
    /// scratch suite in demo mode. One indirection instead of guards at each
    /// call site.
    @ObservationIgnored private let defaults: UserDefaults

    /// Sparkle auto-update (#46). Inert (nil controller) in dev builds, tests
    /// and demo mode — see UpdaterModel.
    let updater: UpdaterModel

    /// Start at Login (#169). Inert in dev builds, tests and demo mode for
    /// the same reasons — see LoginItemModel.
    let loginItem: LoginItemModel

    // MARK: Persisted configuration

    /// The traggo server URL — import-only now: the one-shot importer's
    /// source. (The sync server's URL lives in the store's sync_server row.)
    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }

    /// The saved tag sets, persisted in the local store.
    var tagSets: [TagSet] {
        didSet { persistTagSets() }
    }

    /// Quick labels per label set, keyed by the set's UUID string — one-click
    /// refinements the popover and Launcher offer on hover (#61): a set covers
    /// the focus area (`project:`, `client:`) and a quick label hones in
    /// (`type: review`). Per-set rather than global so e.g. a Workout set
    /// isn't offered `type: design`; the copy/paste clipboard below
    /// spreads one list across sets without retyping. Persisted in the local
    /// store next to the set members, so they ride label-set sync and follow
    /// the user across Macs (#92). Entries for deleted sets linger
    /// harmlessly (in memory only — the store drops them with the set).
    var quickLabels: [String: [TagRow]] {
        didSet { persistQuickLabels() }
    }

    /// The copy/paste clipboard for quick labels in the Label Set editor.
    /// Session-only by design: it's a hand-off between two edits, not state
    /// worth keeping.
    var quickLabelsClipboard: [TagRow]?

    /// The quick labels to offer for a set (empty when none are defined).
    func quickLabels(for set: TagSet) -> [TagRow] {
        quickLabels[set.id.uuidString] ?? []
    }

    /// When on, tags are coloured by their `key: value` pair (using the local
    /// overrides below) instead of only by key, so `recipe: sourdough` and `recipe: focaccia`
    /// can look different. On by default — differentiating spans by value is
    /// Moment Tally's headline improvement over vanilla traggo, with key colours
    /// remaining useful for navigating Tag Review; an explicitly stored false
    /// (a user who turned it off) is respected. Syncs as a user preference
    /// when a server is connected.
    var colorTagsByValue: Bool {
        didSet {
            defaults.set(colorTagsByValue, forKey: Keys.colorTagsByValue)
            preferenceChanged()
        }
    }

    /// Per-`key: value` colour overrides (hex strings), keyed by
    /// `ValueColorKey.join` — first-class rows in the local store, and
    /// per-user (not per-Mac) once a sync server is connected.
    var valueColors: [String: String] {
        didSet { persistValueColors() }
    }

    /// How many tag sets the popover's Quick start list shows, in tag-set
    /// order; 0 means all. Keeps the popover a quick-glance surface when many
    /// sets are saved. Syncs as a user preference when a server is connected.
    var menuTagSetLimit: Int {
        didSet {
            defaults.set(menuTagSetLimit, forKey: Keys.menuTagSetLimit)
            preferenceChanged()
        }
    }

    /// Launcher cards (and the popover's mini tiles) draw the Studio tile
    /// gradient derived from their colour (#201) instead of a flat fill.
    /// Purely cosmetic, so deliberately local-only like `TagSet.colorHex` —
    /// no `preferenceChanged()`, no sync schema change.
    var gradientLauncherCards: Bool {
        didSet { defaults.set(gradientLauncherCards, forKey: Keys.gradientLauncherCards) }
    }

    // MARK: Runtime state (observed by the UI)

    var user: User?
    /// Every running timespan, oldest first — the first-started timer stays at
    /// the top of the popover and new ones join below. Traggo allows
    /// overlapping timespans, and the menu can start one alongside another
    /// (the ＋ on a quick-start row, the blank-timer row), so this is a list
    /// rather than a single timer.
    var activeTimers: [TimeSpan] = []
    var tagDefinitions: [LabelDefinition] = []

    /// The first-started running timespan — the popover's top row and the one
    /// the menu-bar label counts up for.
    var activeTimer: TimeSpan? { activeTimers.first }

    /// The in-flight edit of a running timespan, or nil when nothing is being
    /// edited. One at a time, shared by every editing surface — see
    /// `SpanEditSession`. Surviving here (not in view `@State`) is what lets
    /// drafts outlive the popover closing (#70).
    var editSession: SpanEditSession?
    var errorMessage: String?
    var isBusy = false
    /// Updated once per second while a timer runs so elapsed labels tick.
    var currentDate = Date()

    /// Whether the store is ready to serve data — as soon as it opens (its
    /// `user` is set synchronously); false only if opening the database
    /// failed.
    var isReady: Bool { user != nil }

    /// History (log / calendar / charts) state, split out so this class stays
    /// focused on live-timer concerns.
    @ObservationIgnored private(set) lazy var history = HistoryModel(app: self)

    /// Tag review (cardinality + cleanup) state, split out for the same reason.
    @ObservationIgnored private(set) lazy var review = TagReviewModel(app: self)

    // MARK: Private, non-observed

    /// The saved traggo session token — import-only: it lets a re-import skip
    /// the credential prompt. Not observation-ignored: the import surface's
    /// `hasTraggoSession` reads it, and must react when a one-off login saves
    /// one or an expired one is dropped.
    private var token: String?
    /// The local store — the only backend. Opened at launch and kept open for
    /// the app's lifetime.
    @ObservationIgnored private var localStore: LocalBackend?
    /// Suppresses the tagSets/valueColors/preference persistence observers
    /// while they're being *loaded* (from the store or from a sync pull), so
    /// restoring state never echoes a write or re-dirties a synced record.
    @ObservationIgnored private var isRestoringState = false

    /// Whether the first-run onboarding sequence has been seen (finished or
    /// dismissed — either way it never reappears on its own). Lives in the
    /// defaults suite, so demo launches — whose scratch suite is wiped every
    /// launch — always start with it unset and show the onboarding again.
    /// Read once at launch and written once at the end, so a plain computed
    /// property (not observation-tracked) is enough.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    /// The storage seam, for this model and its siblings (see
    /// `HistoryModel`). Always the local store; the protocol survives
    /// because the importer still consumes arbitrary backends.
    var api: (any Backend)? { localStore }

    /// Where the local database lives, for display in Settings.
    var localDatabasePath: String? {
        localStore?.databaseURL?.path
    }
    @ObservationIgnored private var tickTimer: Timer?
    /// Registration for the CLI's cross-process store-changed notification.
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?
    /// Debounce timers for per-key colour writes, so dragging in the colour
    /// picker doesn't fire an `updateTag` on every intermediate value.
    @ObservationIgnored private var colorTasks: [String: Task<Void, Never>] = [:]

    private enum Keys {
        static let serverURL = "serverURL"
        static let deviceName = "deviceName"
        // Stored under the legacy "presets" key so existing saved sets survive.
        static let tagSets = "presets"
        static let colorTagsByValue = "colorTagsByValue"
        static let valueColors = "valueColors"
        static let menuTagSetLimit = "menuTagSetLimit"
        static let gradientLauncherCards = "gradientLauncherCards"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        /// Keychain accounts: the sync server's device token, and the legacy
        /// traggo token the importer still reuses.
        static let syncToken = "sync-token"
        static let traggoToken = "token"
    }

    // MARK: Lifecycle

    init(demo: Bool = DemoMode.isActive) {
        isDemo = demo
        updater = UpdaterModel(demo: demo)
        loginItem = LoginItemModel(demo: demo)
        let defaults = Self.makeDefaults(demo: demo)
        self.defaults = defaults
        // The fallback doubles as the URL hint in the Traggo import forms —
        // point at the public traggo.net, not an internal host.
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "https://traggo.net"
        deviceName = defaults.string(forKey: Keys.deviceName)
            ?? "Menu Bar (\(Host.current().localizedName ?? "Mac"))"
        colorTagsByValue = defaults.object(forKey: Keys.colorTagsByValue) == nil
            ? true : defaults.bool(forKey: Keys.colorTagsByValue)  // default on
        menuTagSetLimit = defaults.object(forKey: Keys.menuTagSetLimit) == nil
            ? 5 : defaults.integer(forKey: Keys.menuTagSetLimit)  // 0 = all
        gradientLauncherCards = defaults.object(forKey: Keys.gradientLauncherCards) == nil
            ? true : defaults.bool(forKey: Keys.gradientLauncherCards)  // default on
        // Into a local first: `token` is observation-tracked, and a tracked
        // property can't be *read* before the whole object is initialised.
        // A demo never reads the real token — nothing in a demo may reach a
        // real server.
        token = demo ? nil : Keychain.get(account: Keys.traggoToken)
        tagSets = []          // loaded by activateStore()
        valueColors = [:]
        quickLabels = [:]

        activateStore()
        startSyncIfConfigured()
        startTicking()
        startObservingStoreChanges()
        Task { await refresh() }
    }

    /// Demo sessions read and write a scratch suite, wiped on each launch, so
    /// they start from stock settings and a toggle flipped for a screenshot
    /// never lands in the real preferences.
    private static func makeDefaults(demo: Bool) -> UserDefaults {
        guard demo else { return .standard }
        let suite = "MomentTallyDemo"
        let defaults = UserDefaults(suiteName: suite)!   // constant, valid name
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Open the store (running its migrations, including the one-time
    /// UserDefaults import) and load the state it owns.
    private func activateStore() {
        isRestoringState = true
        defer { isRestoringState = false }
        do {
            // Demo mode rebuilds and reseeds demo.sqlite instead —
            // the real database is never even opened.
            localStore = isDemo ? try LocalBackend.demo() : try LocalBackend()
        } catch {
            errorMessage = "Could not open the local database: \(error.localizedDescription)"
        }
        if let store = localStore {
            tagSets = (try? store.loadTagSets()) ?? []
            valueColors = (try? store.loadValueColors()) ?? [:]
            quickLabels = (try? store.loadQuickLabels()) ?? [:]
            user = LocalBackend.localUser   // no login; ready immediately
            // Demo quick labels are keyed by the set ids minted during this
            // launch's reseed, so they can only be attached here, after the
            // sets load. The store write is explicit because the load-time
            // observer suppression is in effect; the reseeded demo store
            // always starts with none, so the seed never overwrites edits.
            if isDemo {
                var seeded: [String: [TagRow]] = [:]
                for set in tagSets {
                    if let rows = DemoSeed.quickLabels(forSetNamed: set.name) {
                        seeded[set.id.uuidString] = rows
                    }
                }
                quickLabels = seeded
                try? store.saveQuickLabels(seeded)
            }
        }
    }

    // MARK: Sync server (#33)

    /// The engine reconciling the store with a connected sync server; nil
    /// when no server is connected (or in demo mode — a demo never syncs).
    var syncEngine: SyncEngine?
    /// The connection row, mirrored from the store for Settings to display.
    var syncServer: SyncServerRow?
    var isConnectingSync = false
    var syncConnectError: String?

    /// Re-attach the engine for a connection that survives a relaunch: an
    /// active sync_server row in the store plus the device token in the
    /// Keychain.
    private func startSyncIfConfigured() {
        guard !isDemo, let store = localStore else { return }
        syncServer = try? store.syncServer()
        guard let row = syncServer, row.active,
              let token = Keychain.get(account: Keys.syncToken),
              let url = URL(string: row.url) else { return }
        startSyncEngine(client: MomentTallyClient(baseURL: url, token: token))
        syncEngine?.kick(after: 1)
    }

    /// Mint a device token on the sync server, remember the connection, and
    /// run the first reconciliation. The password is used once and never
    /// stored; the token goes to the Keychain.
    func connectSyncServer(url: String, username: String, password: String) async {
        guard !isDemo, let store = localStore, !isConnectingSync else { return }
        var normalized = url.trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard let serverURL = URL(string: normalized), serverURL.scheme != nil else {
            syncConnectError = "Invalid server URL"
            return
        }
        isConnectingSync = true
        defer { isConnectingSync = false }
        do {
            var client = MomentTallyClient(baseURL: serverURL, token: nil)
            let result = try await client.login(username: username,
                                                password: password,
                                                deviceName: deviceName)
            Keychain.set(result.token, account: Keys.syncToken)
            try store.connectSyncServer(url: normalized, user: result.user)
            syncServer = try? store.syncServer()
            client.token = result.token
            syncConnectError = nil
            startSyncEngine(client: client)
            await syncEngine?.syncNow()
        } catch {
            syncConnectError = error.localizedDescription
        }
    }

    /// Stop syncing. Local data, server-id mappings, and clean/dirty state
    /// all stay, so reconnecting to the same server resumes instead of
    /// duplicating.
    func disconnectSyncServer() {
        syncEngine?.stop()
        syncEngine = nil
        try? localStore?.disconnectSyncServer()
        Keychain.delete(account: Keys.syncToken)
        syncServer = try? localStore?.syncServer()
    }

    private func startSyncEngine(client: MomentTallyClient) {
        guard let store = localStore else { return }
        let engine = SyncEngine(store: store, server: client)
        engine.readPreferences = { [weak self] in
            (self?.colorTagsByValue ?? true, self?.menuTagSetLimit ?? 5)
        }
        engine.applyPreferences = { [weak self] colorByValue, limit in
            guard let self else { return }
            self.isRestoringState = true
            defer { self.isRestoringState = false }
            self.colorTagsByValue = colorByValue
            self.menuTagSetLimit = limit
        }
        engine.onLocalChange = { [weak self] in
            guard let self else { return }
            self.reloadFromStore()
            self.noteSpanDataChanged()
            Task {
                await self.refresh()
                await self.history.reloadIfLoaded()
            }
        }
        engine.startPeriodicSync()
        syncEngine = engine
    }

    /// Monotonic version of the span data, bumped by every mutation funnel —
    /// timer start/stop/edit here, Log/Calendar edits in `HistoryModel`,
    /// Mark Review rewrites, sync pulls, and the CLI's cross-process signal.
    /// Surfaces that hold their own span snapshot observe it and refetch
    /// when stale instead of asking the user to refresh (#225): compare the
    /// version you loaded at, re-check on appearance, and `.onChange` on it
    /// while visible. Mark Review's `rescanIfStale` is the pattern to copy.
    private(set) var spanDataVersion = 0

    /// Span data changed somewhere — tell observing surfaces. Call it next
    /// to `syncSoon()` on every span write path (and on the pull paths,
    /// which don't sync back).
    func noteSpanDataChanged() {
        spanDataVersion += 1
    }

    /// A local mutation happened — reconcile soon. Called by every write
    /// path here and in the sibling models; harmlessly does nothing when no
    /// server is connected.
    func syncSoon() {
        syncEngine?.kick()
    }

    /// One of the two synced preferences changed by hand: stamp it dirty in
    /// the store (a no-op until a server is connected) and reconcile soon.
    private func preferenceChanged() {
        guard !isRestoringState else { return }
        try? localStore?.markPreferencesDirty()
        syncSoon()
    }

    /// Re-read the state a sync pull may have rewritten (tag sets, quick
    /// labels, value colours) without echoing the loads back as writes.
    private func reloadFromStore() {
        guard let store = localStore else { return }
        isRestoringState = true
        defer { isRestoringState = false }
        let loaded = withCurrentRowIds((try? store.loadTagSets()) ?? [])
        if loaded != tagSets { tagSets = loaded }
        let loadedQuick = withCurrentQuickRowIds((try? store.loadQuickLabels()) ?? [:])
        if loadedQuick != quickLabels { quickLabels = loadedQuick }
        valueColors = (try? store.loadValueColors()) ?? [:]
    }

    /// Loaded sets with `TagRow` ids grafted back from the in-memory sets.
    /// Row ids are view-local and never stored, so a plain reload hands every
    /// row a fresh identity — tearing down whichever field is being edited
    /// and dumping keyboard focus back on the set's Name field (#134).
    private func withCurrentRowIds(_ loaded: [TagSet]) -> [TagSet] {
        let current = Dictionary(uniqueKeysWithValues: tagSets.map { ($0.id, $0.tags) })
        return loaded.map { set in
            guard let oldTags = current[set.id] else { return set }
            var set = set
            set.tags = set.tags.enumerated().map { index, tag in
                var tag = tag
                if index < oldTags.count { tag.id = oldTags[index].id }
                return tag
            }
            return set
        }
    }

    /// The quick-label counterpart of `withCurrentRowIds`, for the same
    /// reason: the editor's quick rows are a `ForEach` over these `TagRow`s.
    private func withCurrentQuickRowIds(_ loaded: [String: [TagRow]]) -> [String: [TagRow]] {
        var result = loaded
        for (setId, rows) in loaded {
            guard let oldRows = quickLabels[setId] else { continue }
            result[setId] = rows.enumerated().map { index, row in
                var row = row
                if index < oldRows.count { row.id = oldRows[index].id }
                return row
            }
        }
        return result
    }

    // MARK: Import from traggo (#30)

    /// Live state of the one-shot traggo import, observed by the Settings
    /// pane. Errors are kept apart from `errorMessage` so a background
    /// refresh can't overwrite a failed import's explanation.
    var isImporting = false
    /// Spans upserted so far, for progress while the import walks pages.
    var importedSpanCount = 0
    var importSummary: ImportSummary?
    var importError: String?

    /// Whether a traggo session is saved (in the Keychain) — the import can
    /// reuse it instead of asking for credentials.
    var hasTraggoSession: Bool { token != nil }

    /// One-shot import of a traggo server's full history into the local
    /// store — `TraggoClient`'s only remaining job. Pass credentials only
    /// when no saved session exists (or the saved one expired): a successful
    /// one-off login keeps its token so re-runs are already signed in.
    func importFromTraggo(username: String = "", password: String = "") async {
        guard !isImporting else { return }
        guard let store = localStore else {
            importError = "The local database isn't open."
            return
        }
        guard let url = URL(string: serverURL) else {
            importError = "Invalid server URL"
            return
        }
        var client = TraggoClient(baseURL: url, token: token)
        isImporting = true
        importedSpanCount = 0
        importSummary = nil
        importError = nil
        defer { isImporting = false }
        do {
            if !username.isEmpty {
                let result = try await client.login(username: username,
                                                    password: password,
                                                    deviceName: deviceName)
                token = result.token
                Keychain.set(result.token, account: Keys.traggoToken)
                client.token = result.token
            } else if try await client.currentUser() == nil {
                // The saved token is dead. Drop it — hasTraggoSession flips,
                // so the credential fields appear next to this explanation.
                token = nil
                Keychain.delete(account: Keys.traggoToken)
                importError = "The saved sign-in has expired — enter your username and password."
                return
            }
            // The origin string namespaces the server's span ids in the local
            // mapping. Use the parsed URL (trailing slash trimmed) so trivial
            // respellings of the same server don't fork the namespace.
            var origin = client.baseURL.absoluteString
            while origin.hasSuffix("/") { origin.removeLast() }
            let importer = HistoryImporter(source: client, destination: store,
                                           origin: origin)
            let summary = try await importer.run { count in
                await MainActor.run { self.importedSpanCount = count }
            }
            importSummary = summary
            // Imported data is live state: running traggo timers now tick in
            // the popover, and key colours reach every tag chip — and it has
            // to reach a connected sync server like any other local write.
            await refresh()
            await history.reloadIfLoaded()
            syncSoon()
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Export (#57)

    /// The store's JSON snapshot, for the Settings export button. Works in
    /// demo mode too — it just snapshots the demo store.
    func exportJSON() throws -> Data {
        guard let store = localStore else {
            throw LocalBackend.Error(message: "The local database isn't open.")
        }
        return try store.exportJSON()
    }

    // MARK: Data

    func refresh() async {
        guard let backend = api, isReady else { return }
        do {
            async let timers = backend.timers()
            async let definitions = backend.labelDefinitions()
            let (runningTimers, labelDefinitions) = try await (timers, definitions)
            activeTimers = runningTimers.sorted { $0.start < $1.start }
            tagDefinitions = labelDefinitions
            pruneEditSession()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: The shared edit session (#61, #70)

    /// Open (or move) the edit session onto this running timespan. The claim
    /// happens synchronously — before the first await — so an editor
    /// rendering off `editSession` never sees a gap while the previous
    /// drafts flush; those are committed right after, because switching
    /// what's being edited must never silently discard an edit (#70).
    func beginEditing(_ span: TimeSpan) async {
        let previous = editSession
        editSession = SpanEditSession(span: span)
        await commit(previous)
    }

    /// `beginEditing` for non-async callers that need the claim in place
    /// before anything else renders (#130: the Calendar→Log hand-off, where
    /// the tab switch lays out the Log synchronously — a claim deferred into
    /// a Task would land after the running row's editor has already rendered
    /// unclaimed and collapsed itself). Claims now, flushes the previous
    /// session's drafts in the background.
    func claimEditingNow(_ span: TimeSpan) {
        let previous = editSession
        editSession = SpanEditSession(span: span)
        Task { await commit(previous) }
    }

    /// Write the session's drafts to its timespan if they changed, staying in
    /// edit mode — the live path behind Return, focus moves, and the popover
    /// closing. Returns false when the write failed (the session stays put so
    /// nothing is lost); a no-op counts as success.
    @discardableResult
    func commitEditSession() async -> Bool {
        await commit(editSession)
    }

    @discardableResult
    private func commit(_ session: SpanEditSession?) async -> Bool {
        guard let session,
              let timer = activeTimers.first(where: { $0.id == session.spanID }),
              session.differs(from: timer)
        else { return true }
        return await updateRunning(id: timer.id, start: session.startDraft,
                                   tags: session.tagDrafts.labels,
                                   note: session.noteDraft)
    }

    /// Commit and close the editor; a failed write keeps it open for a retry.
    func finishEditing() async {
        if await commitEditSession() { editSession = nil }
    }

    /// Close the editor, discarding any uncommitted drafts.
    func cancelEditing() {
        editSession = nil
    }

    /// Drop the session when its timespan is no longer running — stopped or
    /// deleted from any surface, this app or elsewhere. Called wherever
    /// `activeTimers` is rewritten.
    private func pruneEditSession() {
        if let session = editSession,
           !activeTimers.contains(where: { $0.id == session.spanID }) {
            editSession = nil
        }
    }

    func start(tagSet: TagSet) async {
        await start(tags: tagSet.labels)
    }

    /// Start a timespan with the given tags — empty for an ad-hoc timer that
    /// gets classified while it runs. Returns the created timespan so the
    /// caller can e.g. open it for editing right away.
    @discardableResult
    func start(tags: [SpanLabel]) async -> TimeSpan? {
        guard let backend = api else { return nil }
        // Flush any pending edit of another timer first — a quick-start or
        // blank-timer click must not discard drafts sitting in an open
        // editor (#70).
        await commitEditSession()
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureTagDefinitions(for: tags)
            // No note at start; the note is added on the running timer.
            let created = try await backend.startTimeSpan(start: Date(),
                                                          labels: tags,
                                                          note: "")
            activeTimers.append(created)   // newest last, until refresh re-sorts
            errorMessage = nil
            await refresh()
            await history.reloadIfLoaded()
            noteSpanDataChanged()
            syncSoon()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Ensure every tag key exists as a definition, or the server rejects the
    /// timespan. Creates missing ones with a default colour. Delegates to the
    /// backend's idempotent ensure (which checks the store, not our cache) and
    /// refreshes the cache from its result — an edit path that creates a key
    /// mid-session must not leave `tagDefinitions` behind, or the next commit
    /// re-creates the key and hits the duplicate-insert error (#61).
    func ensureTagDefinitions(for tags: [SpanLabel]) async throws {
        guard let backend = api else { return }
        tagDefinitions = try await backend.ensureLabelDefinitions(for: tags,
                                                                  defaultColor: "#2196f3")
    }

    /// Update the start, tags, and note on a running timespan (nil start
    /// preserves the current one). Missing tag definitions are created first
    /// (traggo rejects unknown keys), the same guard `start(tags:)` uses.
    /// Returns whether the write succeeded.
    @discardableResult
    func updateRunning(id: Int, start: Date? = nil,
                       tags: [SpanLabel], note: String) async -> Bool {
        guard let backend = api,
              let span = activeTimers.first(where: { $0.id == id }) else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureTagDefinitions(for: tags)
            let updated = try await backend.updateTimeSpan(
                id: span.id, start: start ?? span.start, end: span.end,
                labels: tags, note: note)
            replaceActiveTimer(with: updated)
            errorMessage = nil
            await history.reloadIfLoaded()
            noteSpanDataChanged()
            syncSoon()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Stop a running timespan — a specific one, or the top row's by default.
    func stop(id: Int? = nil) async {
        guard let backend = api, let target = id ?? activeTimer?.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await backend.stopTimeSpan(id: target, end: Date())
            activeTimers.removeAll { $0.id == target }
            pruneEditSession()
            errorMessage = nil
            await refresh()
            await history.reloadIfLoaded()
            noteSpanDataChanged()
            syncSoon()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reopen a finished timespan (#60): write the given fields with the end
    /// cleared, so it's the running timer again — the recovery for an
    /// accidental stop. The stop is erased and the untracked gap since it is
    /// absorbed into the span, which is the point: "I never meant to stop".
    /// The fields are parameters (not read off the span) so the editor can
    /// reopen with its drafts riding along — Re-Open writes what the panel
    /// shows, minus the end. The cleared end reaches a connected sync server
    /// as an ordinary dirty-span push. Returns the now-running span, nil on
    /// failure, so the caller can move straight into editing it.
    @discardableResult
    func reopen(id: Int, start: Date, tags: [SpanLabel], note: String) async -> TimeSpan? {
        guard let backend = api else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            // The labels are rewritten wholesale by the update; drafted rows
            // may carry new keys, same guard as every edit path.
            try await ensureTagDefinitions(for: tags)
            let updated = try await backend.updateTimeSpan(id: id, start: start,
                                                           end: nil, labels: tags,
                                                           note: note)
            errorMessage = nil
            await refresh()
            await history.reloadIfLoaded()
            noteSpanDataChanged()
            syncSoon()
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func replaceActiveTimer(with updated: TimeSpan) {
        if let index = activeTimers.firstIndex(where: { $0.id == updated.id }) {
            activeTimers[index] = updated
        }
    }

    /// Whether some running timespan reads as this set running — used to dim
    /// the set's Launcher card. Matching by tags (not by which surface was
    /// clicked) also catches a matching timespan started from the web UI, and
    /// the card lights back up naturally when the timespan stops. The rule
    /// (`TagSet.matches(spanLabels:quicks:)`) covers the set's quick-label
    /// starts too — a timer started from a card's quick-mark chip lights that
    /// card (regression flagged in #207).
    func isRunning(_ set: TagSet) -> Bool {
        runningTimer(for: set) != nil
    }

    /// The running timespan reading as this set, if any — same rule as
    /// `isRunning(_:)`. Lets a surface that shows sets (the Launcher) stop
    /// "the set's" timer by id.
    func runningTimer(for set: TagSet) -> TimeSpan? {
        let quicks = quickLabels(for: set)
        return activeTimers.first {
            set.matches(spanLabels: $0.labels, quicks: quicks)
        }
    }

    // MARK: Creating tag sets from existing tags

    /// Whether some saved tag set carries exactly these tags — exact set
    /// equality. Log rows without a match offer "save these tags as a tag
    /// set".
    func hasTagSet(matching tags: [SpanLabel]) -> Bool {
        let want = Set(tags)
        return tagSets.contains { Set($0.labels) == want }
    }

    /// Set when another surface (a Log row's ＋, the Launcher's ＋ card)
    /// creates a tag set and wants the Tag Sets pane to open on it.
    /// Consumed by the pane when it appears or sees the change.
    var pendingTagSetSelection: TagSet.ID?

    /// Append a fresh tag set — seeded from existing tags when given — and
    /// mark it for selection in the Tag Sets pane, where the user names it.
    /// The name starts empty so the editor's Name field is genuinely blank
    /// under its placeholder, not prefilled text to clear first (#134).
    @discardableResult
    func newTagSet(from tags: [SpanLabel] = []) -> TagSet {
        let set = TagSet(tags: tags.map { TagRow(key: $0.key, value: $0.value) })
        tagSets.append(set)
        pendingTagSetSelection = set.id
        return set
    }

    // MARK: Tag colours (stored per key by the backend)

    /// The colour to render a tag with. With "colour by value" on, a
    /// per-value override wins; otherwise the colour the backend has on
    /// record for the tag key, or a sensible default.
    func tagColor(for rawKey: String, value: String? = nil) -> Color {
        if colorTagsByValue, let value,
           let color = valueColor(key: rawKey, value: value) {
            return color
        }
        let key = normalizeKey(rawKey)
        if let hex = tagDefinitions.first(where: { $0.key == key })?.color,
           let color = Color(hex: hex) {
            return color
        }
        return Color(hex: "#2196f3") ?? .blue
    }

    /// The colour a set's launcher card carries: the first mark's colour,
    /// then the set's own fallback (the quick-marks-only case), then accent.
    /// Shared by the Launcher cards and the popover rows' mini tiles, so the
    /// two surfaces always agree.
    func cardTint(for set: TagSet) -> Color {
        if let first = set.labels.first {
            return tagColor(for: first.key, value: first.value)
        }
        return set.colorHex.flatMap(Color.init(hex:)) ?? .accentColor
    }

    // MARK: Per-value colour overrides

    /// The override picked for a `key: value` pair, if any.
    func valueColor(key rawKey: String, value: String) -> Color? {
        guard !value.isEmpty else { return nil }
        return valueColors[ValueColorKey.join(normalizeKey(rawKey), value)]
            .flatMap { Color(hex: $0) }
    }

    func setValueColor(key rawKey: String, value: String, color: Color) {
        guard let hex = color.hexString, !value.isEmpty else { return }
        valueColors[ValueColorKey.join(normalizeKey(rawKey), value)] = hex
    }

    func clearValueColor(key rawKey: String, value: String) {
        valueColors.removeValue(forKey: ValueColorKey.join(normalizeKey(rawKey), value))
    }

    /// A Label Review rewrite respelled labels: their per-value colour
    /// overrides move with them (#69 — without this, renaming a value
    /// silently dropped its colour).
    func migrateValueColors(fromKey: String, fromValue: String?,
                            toKey: String, toValue: String?) {
        valueColors = ValueColorKey.migrating(valueColors,
                                              fromKey: fromKey, fromValue: fromValue,
                                              toKey: toKey, toValue: toValue)
    }

    /// Persist a new colour for a tag key, debounced so a colour-wheel drag
    /// collapses into a single write once it settles.
    func scheduleTagColor(for rawKey: String, color: Color) {
        let key = normalizeKey(rawKey)
        guard !key.isEmpty else { return }
        colorTasks[key]?.cancel()
        colorTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.commitTagColor(key: key, color: color)
        }
    }

    private func commitTagColor(key: String, color: Color) async {
        guard let backend = api, let hex = color.hexString else { return }
        do {
            // update needs an existing key; create reserves a new one.
            if tagDefinitions.contains(where: { $0.key == key }) {
                try await backend.updateLabelDefinition(key: key, color: hex)
            } else {
                try await backend.createLabelDefinition(key: key, color: hex)
            }
            await refresh()   // pull the updated definitions back
            syncSoon()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Menu-bar label + elapsed formatting

    var menuBarLabel: String? {
        guard let active = activeTimer else { return nil }
        return "● " + elapsedString(since: active.start)
    }

    func elapsedString(since start: Date) -> String {
        let seconds = max(0, Int(currentDate.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Ticking

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor to touch state.
            Task { @MainActor in
                guard let self, self.activeTimer != nil else { return }
                self.currentDate = Date()
            }
        }
    }

    /// The moment-tally CLI (#80) writes the store from another process and
    /// posts a distributed notification (see StoreChangeNotification.swift in
    /// MomentTallyCore) — there is no cross-process store observation, so this
    /// is how those writes reach a running app. Re-read the live surfaces and
    /// give sync a kick: a CLI-started span is dirty local data like any
    /// other. Not in demo mode — a demo session runs on its own throwaway
    /// store, not the one the CLI targets.
    private func startObservingStoreChanges() {
        guard !isDemo else { return }
        storeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .momentTallyStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh()
                await self.history.reloadIfLoaded()
                self.noteSpanDataChanged()
                self.syncSoon()
            }
        }
    }

    // MARK: Tag-set + value-colour persistence

    private func persistTagSets() {
        guard !isRestoringState else { return }
        do { try localStore?.saveTagSets(tagSets) }
        catch { errorMessage = error.localizedDescription }
        syncSoon()
    }

    private func persistValueColors() {
        guard !isRestoringState else { return }
        do { try localStore?.saveValueColors(valueColors) }
        catch { errorMessage = error.localizedDescription }
        syncSoon()
    }

    private func persistQuickLabels() {
        guard !isRestoringState else { return }
        do { try localStore?.saveQuickLabels(quickLabels) }
        catch { errorMessage = error.localizedDescription }
        syncSoon()
    }
}
