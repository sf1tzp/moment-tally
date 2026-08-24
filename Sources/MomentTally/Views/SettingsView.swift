import SwiftUI
import MomentTallyCore
import AppKit
import UniformTypeIdentifiers

// The settings window itself (a toolbar-style NSTabViewController) is built in
// SettingsWindowManager. These are the individual section panes it hosts.

// MARK: - Settings (connection + behaviour)

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var syncURL = ""
    @State private var syncUsername = ""
    @State private var syncPassword = ""
    @State private var exportError: String?
    @State private var exportedTo: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Storage") {
                // In demo mode the section is pinned to the demo store, and
                // this note is the mode's one visible indicator (kept out of
                // the popover so screenshots include it only deliberately).
                if model.isDemo {
                    Label("Demo mode", systemImage: "sparkles")
                    Text("Seeded sample data, regenerated on every demo launch. Your real database and settings are untouched — quit and relaunch without MOMENTTALLY_DEMO to get back to them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Everything lives in a local database — no server, no account needed. Connect a sync server below to share your data across Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path = model.localDatabasePath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Save every moment, mark, colour, and tally as a JSON file — an archive of the database above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export as JSON…", action: runExport)
                }
                if let exportedTo {
                    Label("Exported to \(exportedTo)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            // A demo must never reach a real server: no sync, no import.
            if !model.isDemo {
                syncSection
                importSection
            }
            menuAndTagSections
        }
        .formStyle(.grouped)
    }

    // MARK: Sync server (#33)

    /// Connect-to-sync-server flow, and the connection's status once made.
    /// Wording stays product-neutral ("sync server") — the app's own rename
    /// is #34.
    @ViewBuilder
    private var syncSection: some View {
        @Bindable var model = model
        Section("Sync") {
            if let engine = model.syncEngine, let server = model.syncServer {
                LabeledContent("Server", value: server.url)
                LabeledContent("Account", value: server.userName)
                LabeledContent("Status") {
                    switch engine.status {
                    case .syncing:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    case .idle:
                        Label(lastSyncedText(engine.lastSyncedAt),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .error:
                        Label("Offline — changes will sync when the server is reachable",
                              systemImage: "exclamationmark.arrow.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
                if case .error(let message) = engine.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack {
                    Button("Sync now") { Task { await engine.syncNow() } }
                        .disabled(engine.status == .syncing)
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        model.disconnectSyncServer()
                    }
                }
                Text("Everything syncs: moments, mark keys and colours, tallies, and the settings below. Edits made offline catch up on the next sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Optional: connect a sync server to share moments, tallies, and colours across your Macs. Everything keeps working offline; changes sync in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Server URL", text: $syncURL)
                    .autocorrectionDisabled()
                TextField("Username", text: $syncUsername)
                    .autocorrectionDisabled()
                SecureField("Password", text: $syncPassword)
                    .onSubmit(connect)
                TextField("Device name", text: $model.deviceName)
                    .help("How this Mac appears in the server's device list, so you can revoke it later.")
                HStack {
                    if model.isConnectingSync {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("Connect", action: connect)
                        .disabled(syncURL.isEmpty || syncUsername.isEmpty
                            || syncPassword.isEmpty || model.isConnectingSync)
                }
                if let error = model.syncConnectError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        }
    }

    private func lastSyncedText(_ date: Date?) -> String {
        guard let date else { return "Connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func connect() {
        guard !syncURL.isEmpty, !syncUsername.isEmpty, !syncPassword.isEmpty else { return }
        Task {
            await model.connectSyncServer(url: syncURL, username: syncUsername,
                                          password: syncPassword)
            syncPassword = ""   // never keep the password around
        }
    }

    @ViewBuilder
    private var menuAndTagSections: some View {
        @Bindable var model = model
        Section("Menu") {
            // A plain numeric field with its own stepper, like the log
            // editor's time fields. Typed values are clamped on commit.
            let limit = Binding(
                get: { model.menuTagSetLimit },
                set: { model.menuTagSetLimit = max(0, min(99, $0)) })
            LabeledContent("Quick-start tallies") {
                HStack(spacing: 2) {
                    TextField("", value: limit, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 40)
                    Stepper("", value: limit, in: 0...99)
                        .labelsHidden()
                }
            }
            Text("How many tallies the popover lists (0 shows all), in the order from the Tallies tab — drag to reorder there. The rest stay a click away behind a “more…” row.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Launcher") {
            Toggle("Gradient launcher cards", isOn: $model.gradientLauncherCards)
            Text("Cards (and the menu's quick-start tiles) take a colour gradient derived from their colour — the momenttally.com tile look. Off keeps flat colour fills.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Marks") {
            Toggle("Colour marks by value", isOn: $model.colorTagsByValue)
            Text("Pick a colour per key: value pair, so e.g. recipe: sourdough and recipe: focaccia look different. Pairs without an override keep their key colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Start at Login (#169). Absent from dev builds and demos, where
        // there is no bundle to register — see LoginItemModel.
        if model.loginItem.isAvailable {
            @Bindable var loginItem = model.loginItem
            Section("Login") {
                Toggle("Start Moment Tally at login", isOn: $loginItem.startsAtLogin)
                if loginItem.requiresApproval {
                    // Switched off behind the app's back — only System
                    // Settings can turn it back on.
                    HStack {
                        Text("Switched off in System Settings › Login Items. Turn it back on there — the toggle above can’t override it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                } else {
                    Text("Opens Moment Tally in the menu bar when you log in to this Mac. A per-Mac setting — it doesn’t sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        }
        // Sparkle (#46). Absent from dev builds and demos, where there is no
        // updater to configure.
        if model.updater.isAvailable {
            @Bindable var updater = model.updater
            Section("Updates") {
                Toggle("Check for updates in the background",
                       isOn: $updater.automaticallyChecksForUpdates)
                Text("Checks about once a day and offers new versions when they appear. Off means updates only come from “Check for Updates…” in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Import from traggo (#30)

    /// The one-shot importer's surface. Reuses the saved traggo session when
    /// one exists; otherwise asks for a one-off sign-in whose token is kept,
    /// so re-runs are already signed in.
    private var importSection: some View {
        @Bindable var model = model
        return Section("Import from Traggo") {
            Text("Copy a Traggo server’s full history — finished and running moments, plus mark keys and their colours — into the local database. Safe to run again: moments already imported are updated, not duplicated.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Server URL", text: $model.serverURL)
            if model.hasTraggoSession {
                Text("Using the saved Traggo sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }
            HStack {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                    Text("Imported \(model.importedSpanCount) moments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import from Traggo…", action: runImport)
                    .disabled(model.isImporting
                        || (!model.hasTraggoSession && (username.isEmpty || password.isEmpty)))
            }
            if let summary = model.importSummary {
                Label(summaryText(summary), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = model.importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func summaryText(_ summary: ImportSummary) -> String {
        var parts = ["Imported \(summary.spansImported) moments"]
        if summary.spansUpdated > 0 {
            parts.append("(\(summary.spansInserted) new, \(summary.spansUpdated) updated)")
        }
        if summary.runningSpans > 0 {
            parts.append("— \(summary.runningSpans) still running —")
        }
        parts.append("and \(summary.definitionsCreated + summary.definitionsRecolored) mark keys.")
        return parts.joined(separator: " ")
    }

    private func runImport() {
        Task {
            await model.importFromTraggo(username: username, password: password)
            password = ""   // never keep the password around
        }
    }

    // MARK: Export to JSON (#57)

    /// Ask where to save, then write the store's snapshot there. The panel
    /// runs modal: the settings window is a plain AppKit window and the
    /// export itself is a synchronous single-file read.
    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Moment Tally Export \(Self.filenameDate.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportedTo = nil
        exportError = nil
        do {
            try model.exportJSON().write(to: url)
            exportedTo = url.lastPathComponent
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// The default filename's date stamp — the user's calendar day, safe in a
    /// filename (no colons or slashes).
    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Tallies

struct TagSetsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TagSet.ID?
    @State private var pendingDelete: TagSet?

    var body: some View {
        splitView
            // Pre-select a set so the editor is populated on open: one handed
            // over from another surface (Log ＋ / Launcher ＋ card) wins,
            // otherwise the first set.
            .onAppear { consumePendingSelection() }
            .onChange(of: model.pendingTagSetSelection) { consumePendingSelection() }
            .confirmationDialog(
                "Delete “\(pendingDelete.map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "")”?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let set = pendingDelete {
                        model.tagSets.removeAll { $0.id == set.id }
                    }
                }
            } message: {
                Text("This will remove the tally. Existing moment marks will be unaffected.")
            }
    }

    /// Deleting an empty set loses nothing, so it skips the dialog; a set
    /// with labels asks first (#106).
    private func requestDelete(_ set: TagSet) {
        if set.tags.isEmpty {
            model.tagSets.removeAll { $0.id == set.id }
        } else {
            pendingDelete = set
        }
    }

    private func consumePendingSelection() {
        if let pending = model.pendingTagSetSelection {
            selection = pending
            model.pendingTagSetSelection = nil
        } else if selection == nil {
            selection = model.tagSets.first?.id
        }
    }

    private var splitView: some View {
        @Bindable var model = model
        return HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.tagSets) { set in
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                            .tag(set.id)
                    }
                    .onDelete { offsets in
                        if let index = offsets.first {
                            requestDelete(model.tagSets[index])
                        }
                    }
                    // Order matters: the popover shows the first N sets.
                    .onMove { model.tagSets.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack {
                    Button {
                        // Selection arrives via pendingTagSetSelection — the
                        // same route the Launcher ＋ card and Log ＋ use.
                        model.newTagSet()
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selection,
                           let set = model.tagSets.first(where: { $0.id == selection }) {
                            requestDelete(set)
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 160)

            if let index = model.tagSets.firstIndex(where: { $0.id == selection }) {
                TagSetDetailView(tagSet: $model.tagSets[index])
            } else {
                VStack {
                    Spacer()
                    Text("Select or add a tally")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct TagSetDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var tagSet: TagSet
    @FocusState private var nameFocused: Bool
    /// The row being drag-reordered — see RowReorder.swift.
    @State private var dragged: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // The preview leads (#179): what the edits below add up to,
            // floating over the window background above the scrolling form.
            TagSetPreview(tagSet: tagSet)
            editorForm
        }
    }

    private var editorForm: some View {
        Form {
            Section("Tally") {
                // "Untitled" matches the fallback shown wherever an unnamed
                // set is listed, so the placeholder tells the truth (#134).
                // An explicit label + hidden-label field, like the key/value
                // rows: the grouped Form right-justifies a *labelled*
                // TextField's text (multilineTextAlignment doesn't override
                // it), which hides a trailing space as it's typed (#175).
                HStack {
                    Text("Name")
                    TextField("Name", text: $tagSet.name, prompt: Text("Untitled"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .focused($nameFocused)
                }
            }
            Section("Marks") {
                ForEach($tagSet.tags) { $tag in
                    HStack(spacing: 6) {
                        RowReorderGrip(tag: tag, dragged: $dragged)
                        // With no effective labels every row is keyless, so
                        // instead of a disabled swatch each row offers the
                        // set's fallback card colour — the first place a
                        // quick-labels-only set's owner looks for it. The
                        // first typed key swaps it back to the tag picker.
                        if tagSet.labels.isEmpty {
                            CardColorPicker(colorHex: $tagSet.colorHex)
                        } else {
                            TagColorPicker(key: tag.key, value: tag.value)
                        }
                        // labelsHidden + prompt: the grouped Form would
                        // otherwise render the titles as row labels — the
                        // editors use in-field hints instead.
                        TextField("key", text: $tag.key, prompt: Text("key"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .autocorrectionDisabled()
                            .frame(width: LabelEditorStyle.keyFieldWidth)
                        Text(":").foregroundStyle(.secondary)
                        TextField("value", text: $tag.value, prompt: Text("value"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .autocorrectionDisabled()
                        Button(role: .destructive) {
                            // Read the id before removeAll — reading the
                            // `tag` binding inside the predicate re-enters
                            // the array's exclusive access and traps.
                            let id = tag.id
                            tagSet.tags.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .rowReorderDrop(tag, rows: $tagSet.tags, dragged: $dragged)
                }
                HStack(spacing: 6) {
                    // A set with no rows at all (quick labels do the work)
                    // still needs somewhere to pick its card colour — the
                    // swatch sits where the first row's would.
                    if tagSet.tags.isEmpty {
                        CardColorPicker(colorHex: $tagSet.colorHex)
                    }
                    Button {
                        tagSet.tags.append(TagRow())
                    } label: {
                        Label("Add Mark", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                Text("Keys are lower-cased with spaces turned into “-”. Missing keys are created automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(colorCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if tagSet.labels.isEmpty {
                    Text("With no marks, the swatch picks this tally’s Launcher card colour instead. Card colours are saved on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            quickLabelsSection
            // Last deliberately: the icon is cosmetic next to the labels and
            // quick labels that define what the set *does*.
            Section("Launcher icon") {
                SymbolPicker(selection: $tagSet.symbolName)
            }
        }
        .formStyle(.grouped)
        // Added (or reordered, #155) rows otherwise leave Tab unreachable or
        // walking the old order — see KeyViewLoopRefresher.
        .refreshesKeyViewLoop(on: "\(tagSet.id)/\(tagSet.tags.map(\.id))/\(quickRows.wrappedValue.map(\.id))")
        // A freshly created set lands here unnamed: put the cursor in the
        // empty Name field so typing the name is the next keystroke (#134).
        // onChange too — the editor keeps its structural identity when the
        // sidebar selection moves, so onAppear alone misses set switches.
        .onAppear { if tagSet.name.isEmpty { nameFocused = true } }
        .onChange(of: tagSet.id) { if tagSet.name.isEmpty { nameFocused = true } }
    }

    /// This set's quick labels (#61): hovering the set in the popover or
    /// Launcher offers them as one-click chips that start the set plus that
    /// label. Copy/Paste spreads one list across sets without retyping —
    /// the clipboard lives on the model, so it survives switching sets.
    private var quickLabelsSection: some View {
        Section {
            ForEach(quickRows) { $tag in
                HStack(spacing: 6) {
                    RowReorderGrip(tag: tag, dragged: $dragged)
                    TagColorPicker(key: tag.key, value: tag.value)
                    TextField("key", text: $tag.key, prompt: Text("key"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .autocorrectionDisabled()
                        .frame(width: LabelEditorStyle.keyFieldWidth)
                    Text(":").foregroundStyle(.secondary)
                    TextField("value", text: $tag.value, prompt: Text("value"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .autocorrectionDisabled()
                    Button(role: .destructive) {
                        // Read the id before removeAll — reading the `tag`
                        // binding inside the predicate re-enters the array's
                        // exclusive access and traps.
                        let id = tag.id
                        quickRows.wrappedValue.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .rowReorderDrop(tag, rows: quickRows, dragged: $dragged)
            }
            Button {
                quickRows.wrappedValue.append(TagRow())
            } label: {
                Label("Add Quick Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Text("Offered as one-click chips when hovering this tally in the menu or Launcher: click one to start the tally plus that mark. If the tally already carries the same key, the quick mark’s value wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Quick marks")
                Spacer()
                Button("Copy") {
                    model.quickLabelsClipboard = quickRows.wrappedValue
                }
                .disabled(quickRows.wrappedValue.isEmpty)
                Button("Paste") {
                    if let rows = model.quickLabelsClipboard {
                        quickRows.wrappedValue = rows
                    }
                }
                .disabled(model.quickLabelsClipboard == nil)
            }
            .buttonStyle(.borderless)
        }
    }

    /// The editable rows behind this set's quick labels — a binding into the
    /// model's per-set dictionary, so edits persist through its observer.
    private var quickRows: Binding<[TagRow]> {
        Binding(
            get: { model.quickLabels[tagSet.id.uuidString] ?? [] },
            set: { model.quickLabels[tagSet.id.uuidString] = $0 })
    }

    /// Key and value colours both live in the local database (and follow the
    /// user across Macs once a sync server is connected), so the story is
    /// just "per pair" vs "per key".
    private var colorCaption: String {
        model.colorTagsByValue
            ? "Colours are saved per key: value pair and override the key’s colour. Right-click a swatch to go back to the key colour."
            : "Colours are saved per mark key, so recolouring a key here also changes it in every other tally that uses it."
    }
}

/// The fallback-colour swatch for a set's launcher card, shown in place of
/// `TagColorPicker` when the set has no labels to borrow a colour from (a
/// quick-labels-only set). Binds straight to `TagSet.colorHex` — a per-set,
/// local-only colour, unlike the shared tag palette the other swatches edit.
/// Right-click to go back to the accent colour.
private struct CardColorPicker: View {
    @Binding var colorHex: String?

    var body: some View {
        ColorPicker("", selection: Binding(
            get: { colorHex.flatMap(Color.init(hex:)) ?? .accentColor },
            set: { colorHex = $0.hexString }
        ), supportsOpacity: false)
        .labelsHidden()
        .contextMenu {
            Button("Use accent colour") { colorHex = nil }
                .disabled(colorHex == nil)
        }
        .help("Launcher card colour")
    }
}

/// A curated SF Symbols grid for the launcher-card icon — deliberately not a
/// full symbol browser — plus a free-text field for any other SF Symbols name
/// (issue #65). `nil` selection renders (and highlights) the default "tag"
/// symbol.
private struct SymbolPicker: View {
    @Binding var selection: String?

    private static let choices = [
        TagSet.markSymbol,
        "tag", "laptopcomputer", "terminal", "hammer", "wrench.and.screwdriver",
        "doc.text", "book", "graduationcap", "brain", "lightbulb",
        "person.2", "phone", "envelope", "bubble.left.and.bubble.right", "calendar",
        "cup.and.saucer", "fork.knife", "figure.walk", "figure.run", "bed.double",
        "house", "car", "cart", "globe", "leaf",
        "gamecontroller", "music.note", "paintbrush", "camera", "shippingbox",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 4)],
                      spacing: 4) {
                ForEach(Self.choices, id: \.self) { symbol in
                    let selected = symbol == (selection ?? TagSet.markSymbol)
                    Button {
                        selection = symbol
                    } label: {
                        Group {
                            if symbol == TagSet.markSymbol {
                                TallyMarkIcon(size: 15, inset: Brand.symbolInset)
                            } else {
                                Image(systemName: symbol)
                            }
                        }
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color.accentColor.opacity(0.25) : .clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selected ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.borderless)
                    .help(symbol)
                }
            }
            HStack(spacing: 4) {
                TextField("Symbol name", text: typedName, prompt: Text("SF Symbol name"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !selectionResolves {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("No SF Symbol with this name")
                }
            }
            if !selectionResolves {
                Text("Not a known SF Symbols name — the launcher card will show no icon until it is corrected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Mirrors `selection` so a click on a grid tile fills the field and a
    /// typed name drives the same binding a click does (an exact match of a
    /// curated symbol therefore highlights its tile). Empty means "use the
    /// default", i.e. `nil`.
    private var typedName: Binding<String> {
        Binding(
            get: { selection ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                selection = trimmed.isEmpty ? nil : trimmed
            })
    }

    /// SF Symbols names are easy to mistype, so resolve the current one and
    /// flag it inline when it isn't real (also covers bad names that synced
    /// in from elsewhere). `nil` falls back to the brand mark. So does the
    /// reserved mark name, which is deliberately not a real symbol and would
    /// otherwise be flagged as the very typo this is looking for.
    private var selectionResolves: Bool {
        guard let name = selection, name != TagSet.markSymbol else { return true }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
