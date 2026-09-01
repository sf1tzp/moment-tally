import SwiftUI
import MomentTallyCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The settings window itself (a toolbar-style NSTabViewController) is built in
// SettingsWindowManager. These are the individual section panes it hosts.

// MARK: - Settings (connection + behaviour)

/// Generic over the shell's own settings sections: Sparkle and Start at
/// Login are Mac-shell concerns whose types this module cannot see, so the
/// Mac window passes them in as trailing content (#125); iOS passes none.
package struct GeneralSettingsView<PlatformSections: View>: View {
    @Environment(AppModel.self) private var model
    private let platformSections: PlatformSections
    @State private var username = ""
    @State private var password = ""
    @State private var syncURL = ""
    @State private var syncUsername = ""
    @State private var syncPassword = ""
    @State private var exportError: String?
    @State private var exportedTo: String?
    @State private var exportDocument: JSONExportDocument?
    @State private var showExporter = false

    package init(@ViewBuilder platformSections: () -> PlatformSections) {
        self.platformSections = platformSections()
    }

    package var body: some View {
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
                    Text("Save every moment, mark, color, and tally as a JSON file — an archive of the database above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export as JSON…", action: prepareExport)
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
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url): exportedTo = url.lastPathComponent
            case .failure(let error): exportError = error.localizedDescription
            }
        }
    }

    // MARK: Sync (#33 self-hosted, #121 iCloud)

    /// The two mutually exclusive sync transports: status once one is
    /// connected, the chooser when none is. Wording stays product-neutral
    /// ("sync server") for the self-hosted side — the app's own rename
    /// is #34.
    @ViewBuilder
    private var syncSection: some View {
        @Bindable var model = model
        Section("Sync") {
            if let cloud = model.cloudSync {
                LabeledContent("Service", value: "iCloud")
                LabeledContent("Status") {
                    syncStatusLabel(cloud.status, lastSyncedAt: cloud.lastSyncedAt,
                                    offlineText: "Offline — changes will sync when iCloud is reachable")
                }
                if case .error(let message) = cloud.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack {
                    Button("Sync now") { Task { await cloud.syncNow() } }
                        .disabled(cloud.status == .syncing)
                    Spacer()
                    Button("Turn Off iCloud Sync", role: .destructive) {
                        model.disconnectCloudKit()
                    }
                }
                Text("Everything syncs through your iCloud account: moments, mark keys and colors, tallies, and the settings below. End-to-end encrypted — neither Apple nor Street Fortress can read your data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let engine = model.syncEngine, let server = model.syncServer {
                LabeledContent("Server", value: server.url)
                LabeledContent("Account", value: server.userName)
                LabeledContent("Status") {
                    syncStatusLabel(engine.status, lastSyncedAt: engine.lastSyncedAt,
                                    offlineText: "Offline — changes will sync when the server is reachable")
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
                Text("Everything syncs: moments, mark keys and colors, tallies, and the settings below. Edits made offline catch up on the next sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if BuildEntitlements.cloudKitAvailable {
                    HStack {
                        Text("Sync across your devices with iCloud — no account setup, end-to-end encrypted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use iCloud") { Task { await model.connectCloudKit() } }
                            .disabled(model.isConnectingSync)
                    }
                    Divider()
                }
                Text("Optional: connect a self-hosted sync server to share moments, tallies, and colors across your Macs. Everything keeps working offline; changes sync in the background.")
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

    @ViewBuilder
    private func syncStatusLabel(_ status: SyncStatus, lastSyncedAt: Date?,
                                 offlineText: String) -> some View {
        switch status {
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
        case .idle:
            Label(lastSyncedText(lastSyncedAt), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Label(offlineText, systemImage: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)
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
        Section("Marks") {
            Toggle("Color marks by value", isOn: $model.colorTagsByValue)
            Text("Pick a color per key: value pair, so e.g. recipe: sourdough and recipe: focaccia look different. Pairs without an override keep their key color.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show keys on quick label chips", isOn: $model.showQuickLabelKeys)
            Text("Chips in the menu and on Launcher cards read “+type: review” instead of “+review” — handy when a tally’s quick labels span several keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        platformSections
    }

    // MARK: Import from traggo (#30)

    /// The one-shot importer's surface. Reuses the saved traggo session when
    /// one exists; otherwise asks for a one-off sign-in whose token is kept,
    /// so re-runs are already signed in.
    private var importSection: some View {
        @Bindable var model = model
        return Section("Import from Traggo") {
            Text("Copy a Traggo server’s full history — finished and running moments, plus mark keys and their colors — into the local database. Safe to run again: moments already imported are updated, not duplicated.")
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

    /// Snapshot the store, then hand the bytes to `fileExporter` — the one
    /// cross-platform save flow (#125 retired the Mac's NSSavePanel for it).
    /// The read is synchronous and single-file, so snapshotting before the
    /// picker appears is fine and surfaces store errors immediately.
    private func prepareExport() {
        exportedTo = nil
        exportError = nil
        do {
            exportDocument = JSONExportDocument(data: try model.exportJSON())
            showExporter = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportFilename: String {
        "Moment Tally Export \(exportFilenameDate.string(from: Date()))"
    }

}

extension GeneralSettingsView where PlatformSections == EmptyView {
    /// The no-platform-sections case (iOS): nothing to append to the form.
    package init() {
        self.init { EmptyView() }
    }
}

/// The default export filename's date stamp — the user's calendar day, safe
/// in a filename (no colons or slashes). File-scope: generic types can't
/// hold static stored properties.
private let exportFilenameDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - Tallies

package struct TagSetsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TagSet.ID?
    @State private var pendingDelete: TagSet?
    /// iOS: the pushed detail (the Mac shows a sidebar + detail split).
    @State private var path: [TagSet.ID] = []

    package init() {}

    package var body: some View {
        platformBody
            // Pre-select a set so the editor is populated on open: one handed
            // over from another surface (Log ＋ / Launcher ＋ card) wins,
            // otherwise the first set (Mac; iOS pushes only on hand-over).
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
        #if os(macOS)
        if let pending = model.pendingTagSetSelection {
            selection = pending
            model.pendingTagSetSelection = nil
        } else if selection == nil {
            selection = model.tagSets.first?.id
        }
        #else
        if let pending = model.pendingTagSetSelection {
            path = [pending]
            model.pendingTagSetSelection = nil
        }
        #endif
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        splitView
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    /// The list-and-push shape (#125): rows reorder with the standard edit
    /// mode (order matters — the popover and home grid read the first N),
    /// swipe deletes, ＋ creates and pushes via the same
    /// `pendingTagSetSelection` hand-over the Mac surfaces use.
    private var iosBody: some View {
        @Bindable var model = model
        return NavigationStack(path: $path) {
            List {
                ForEach(model.tagSets) { set in
                    NavigationLink(value: set.id) {
                        HStack(spacing: 12) {
                            LauncherTileIcon(set: set, size: 28)
                            Text(set.name.isEmpty ? "Untitled" : set.name)
                        }
                    }
                }
                .onDelete { offsets in
                    if let index = offsets.first {
                        requestDelete(model.tagSets[index])
                    }
                }
                .onMove { model.tagSets.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationTitle("Tallies")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TagSet.ID.self) { id in
                if let index = model.tagSets.firstIndex(where: { $0.id == id }) {
                    TagSetDetailView(tagSet: $model.tagSets[index])
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.newTagSet()
                    } label: {
                        Label("New Tally", systemImage: "plus")
                    }
                }
            }
        }
    }
    #endif

    #if os(macOS)
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
    #endif
}

package struct TagSetDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding package var tagSet: TagSet
    @FocusState private var nameFocused: Bool
    /// The row being drag-reordered — see RowReorder.swift.
    @State private var dragged: UUID?

    package init(tagSet: Binding<TagSet>) {
        self._tagSet = tagSet
    }

    package var body: some View {
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
                        #if os(macOS)
                        RowReorderGrip(tag: tag, dragged: $dragged)
                        #endif
                        // With no effective labels every row is keyless, so
                        // instead of a disabled swatch each row offers the
                        // set's fallback card color — the first place a
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
                        // iOS deletes by swipe and reorders in edit mode;
                        // the Mac keeps the per-row minus and drag grip.
                        #if os(macOS)
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
                        #endif
                    }
                    #if os(macOS)
                    .rowReorderDrop(tag, rows: $tagSet.tags, dragged: $dragged)
                    #endif
                }
                #if os(iOS)
                .onDelete { tagSet.tags.remove(atOffsets: $0) }
                .onMove { tagSet.tags.move(fromOffsets: $0, toOffset: $1) }
                #endif
                HStack(spacing: 6) {
                    // A set with no rows at all (quick labels do the work)
                    // still needs somewhere to pick its card color — the
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
                    Text("With no marks, the swatch picks this tally’s Launcher card color instead. Card colors are saved on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            quickLabelsSection
            // Last deliberately: the card's look is cosmetic next to the
            // labels and quick labels that define what the set *does*.
            Section("Launcher card") {
                SymbolPicker(selection: $tagSet.symbolName)
                // Per-card since #226 — one gradient per grid read fine, a
                // whole grid of neighbouring hues did not. Unset means on.
                Toggle("Color gradient", isOn: Binding(
                    get: { tagSet.gradient ?? true },
                    set: { tagSet.gradient = $0 }))
                Text("The card (and the menu's quick-start tile) takes the moment-tally.com tile gradient derived from its color. Off keeps a flat fill. Saved on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        #if os(iOS)
        .navigationTitle(tagSet.name.isEmpty ? "Untitled" : tagSet.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        #endif
    }

    /// This set's quick labels (#61): hovering the set in the popover or
    /// Launcher offers them as one-click chips that start the set plus that
    /// label. Copy/Paste spreads one list across sets without retyping —
    /// the clipboard lives on the model, so it survives switching sets.
    private var quickLabelsSection: some View {
        Section {
            ForEach(quickRows) { $tag in
                HStack(spacing: 6) {
                    #if os(macOS)
                    RowReorderGrip(tag: tag, dragged: $dragged)
                    #endif
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
                    #if os(macOS)
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
                    #endif
                }
                #if os(macOS)
                .rowReorderDrop(tag, rows: quickRows, dragged: $dragged)
                #endif
            }
            #if os(iOS)
            .onDelete { quickRows.wrappedValue.remove(atOffsets: $0) }
            .onMove { quickRows.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
            #endif
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

    /// Key and value colors both live in the local database (and follow the
    /// user across Macs once a sync server is connected), so the story is
    /// just "per pair" vs "per key".
    private var colorCaption: String {
        model.colorTagsByValue
            ? "Colors are saved per key: value pair and override the key’s color. Right-click a swatch to go back to the key color."
            : "Colors are saved per mark key, so recoloring a key here also changes it in every other tally that uses it."
    }
}

/// The fallback-color swatch for a set's launcher card, shown in place of
/// `TagColorPicker` when the set has no labels to borrow a color from (a
/// quick-labels-only set). Binds straight to `TagSet.colorHex` — a per-set,
/// local-only color, unlike the shared tag palette the other swatches edit.
/// Right-click to go back to the accent color.
private struct CardColorPicker: View {
    @Binding var colorHex: String?

    var body: some View {
        ColorPicker("", selection: Binding(
            get: { colorHex.flatMap(Color.init(hex:)) ?? .accentColor },
            set: { colorHex = $0.hexString }
        ), supportsOpacity: false)
        .labelsHidden()
        .contextMenu {
            Button("Use accent color") { colorHex = nil }
                .disabled(colorHex == nil)
        }
        .help("Launcher card color")
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
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return UIImage(systemName: name) != nil
        #endif
    }
}

/// The export payload as a `FileDocument`, so both platforms share
/// `fileExporter` for Save-as-JSON (#57/#125). Write-only in practice —
/// reading exists to satisfy the protocol (and round-trips the bytes).
package struct JSONExportDocument: FileDocument {
    package static let readableContentTypes: [UTType] = [.json]
    package let data: Data

    package init(data: Data) {
        self.data = data
    }

    package init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    package func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
