import SwiftUI
import MomentTallyCore
import MomentTallyKit
import AppKit

/// The contents of the menu-bar popover.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdaterModel.self) private var updater

    // The edit drafts live in `model.editSession`, shared with the Log
    // view's running-row editor (#61) and surviving the popover closing
    // (#70) — this view only tracks focus.

    /// Which editor field holds focus. Return in a tag field, or focus
    /// moving at all ("clicking off"), commits the drafts so the pills
    /// above update reactively — the editor stays open.
    private enum EditorField: Hashable {
        case key(UUID), value(UUID), note
    }
    @FocusState private var focusedField: EditorField?
    /// Measured height of a timer-editor label row, for the gesture-driven
    /// reorder's slot math — see GestureReorderGrip in RowReorder.swift.
    @State private var editorRowHeight: CGFloat = 24

    /// One-shot request from the quick-start path (#149): a set with a
    /// value-less label (`issue:` — a key whose value is typed fresh each
    /// start) opens the new span's editor, and the editor's appearance
    /// consumes this to land focus on that value field. Focus can't be set
    /// at start time — the field doesn't exist until the editor renders.
    @State private var wantsValueFocusOnEditorAppear = false

    /// The quick-start row whose quick-label chips are expanded — set only
    /// after the pointer *rests* on the row (hover intent, below), so the
    /// list stays glanceable at rest and a quick sweep down the menu to the
    /// shortcut rows doesn't expand and collapse every row it crosses.
    @State private var hoveredQuickStartID: TagSet.ID?
    /// The row a delayed expansion is armed for, and its timer.
    @State private var pendingHoverID: TagSet.ID?
    @State private var hoverIntentTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isReady {
                readyBody
            } else {
                notReadyBody
            }
        }
        .padding(12)
        // Refresh whenever the popover opens so we reflect changes made in the
        // web UI without waiting for the 30s poll.
        .task {
            await model.refresh()
        }
        // Closing the popover commits pending drafts (the session itself
        // survives in the model, so reopening resumes the edit) — with
        // view-local drafts this teardown was where edits silently died (#70).
        .onDisappear {
            Task { await model.commitEditSession() }
            // A color panel opened from the timer editor would otherwise
            // linger with nothing to sweep it up (#142).
            NSColorPanel.closeShared()
        }
    }

    /// The store is ready the moment it opens, so this shows only if the
    /// local database failed to open.
    @ViewBuilder
    private var notReadyBody: some View {
        Text("Local database unavailable")
            .font(.headline)
        Text("Check the error below, then relaunch the app.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let error = model.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }

        Divider()

        VStack(spacing: 2) {
            Button {
                openSettings(tab: .settings)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Moment Tally", systemImage: "power")
            }
            .buttonStyle(MenuRowButtonStyle())
        }
        .font(.callout)
    }

    @ViewBuilder
    private var readyBody: some View {
        activeTimerSection

        Divider()

        Text("Quick start")
            .font(.caption)
            .foregroundStyle(.secondary)

        if model.tagSets.isEmpty {
            Text("No tallies yet — add some in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Running sets stay listed: starting one again is legitimate now
            // that a set can run several times concurrently under different
            // quick labels (untangling the overlap is the query side's job).
            // The cap (0 = all) hides the rest behind a "more…" row so the
            // popover stays glanceable.
            let candidates = model.tagSets
            let limit = model.menuTagSetLimit
            let visibleSets = limit > 0 ? Array(candidates.prefix(limit)) : candidates
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleSets) { set in
                    quickStartRow(set)
                }
                if candidates.count > visibleSets.count {
                    // The launcher is the "see everything" surface.
                    Button {
                        openSettings(tab: .launcher)
                    } label: {
                        Text("\(candidates.count - visibleSets.count) more…")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(MenuRowButtonStyle())
                }
            }
        }

        if let error = model.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }

        Divider()

        // Full-width rows, like Rectangle's menu: quick access to the content
        // tabs of the settings window, then the config surfaces (Tallies,
        // Settings) and Quit.
        VStack(spacing: 2) {

            Button {
                openSettings(tab: .tagSets)
            } label: {
                Label { Text("Tallies")} icon: { TallyMarkIcon().padding(.leading, 0.9) }
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                openSettings(tab: .log)
            } label: {
                Label("Log", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                openSettings(tab: .calendar)
            } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                openSettings(tab: .history)
            } label: {
                Label("History", systemImage: "chart.pie")
            }
            .buttonStyle(MenuRowButtonStyle())

            Divider()


            Button {
                openSettings(tab: .settings)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(MenuRowButtonStyle())

            // Help used to be reachable only by finding its tab inside the
            // settings window — give it a row of its own (#192).
            Button {
                openSettings(tab: .help)
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .buttonStyle(MenuRowButtonStyle())

            // Only in installed builds — dev builds and demos have no updater.
            if updater.isAvailable {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(MenuRowButtonStyle())
                .disabled(!updater.canCheckForUpdates)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Moment Tally", systemImage: "power")
            }
            .buttonStyle(MenuRowButtonStyle())
        }
        .font(.callout)
    }

    private func openSettings(tab: SettingsTab) {
        SettingsWindowManager.shared.show(model: model, tab: tab)
    }

    /// One quick-start row. The row starts the set — alongside any running
    /// timers (overlapping timespans are supported), the same semantics as a
    /// Launcher card, so rows never grey out while something runs. Hovering
    /// the row reveals the quick-label chips (when any are defined): one
    /// click starts the set plus that label. The hover treatment is an accent
    /// *outline* drawn here, around the whole expanded area, so it covers the
    /// chips too and survives the mouse moving from the button onto a chip;
    /// the button style's own accent fill is off (it would end at the
    /// button's edge), and the row keeps its normal text colors.
    private func quickStartRow(_ set: TagSet) -> some View {
        let expanded = hoveredQuickStartID == set.id
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                Task { await quickStart(labels: set.labels) }
            } label: {
                // The mini tile carries the set's launcher-card identity into
                // the popover (#201); .top so it stays with the name row when
                // pills wrap below.
                HStack(alignment: .top, spacing: 8) {
                    LauncherTileIcon(set: set)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                        let tags = set.tags.filter { !$0.key.isEmpty }
                        if !tags.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(tags) { tag in
                                    TagPill(key: tag.key, value: tag.value,
                                            color: model.tagColor(for: tag.key, value: tag.value))
                                }
                            }
                        }
                    }
                }
            }
            .buttonStyle(MenuRowButtonStyle(fillsOnHover: false))
            .disabled(model.isBusy)

            let quicks = model.quickLabels(for: set)
            if expanded, !quicks.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(quicks) { quick in
                        QuickLabelChip(set: set, quick: quick) {
                            await quickStart(labels: $0)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Radius 8 rhymes with the chips' capsule ends (they're ~17pt tall)
        // better than the menu rows' 5 does.
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(expanded ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .onHover { rowHovered(set, inside: $0) }
    }

    /// Start a set from its quick-start row or one of its quick-label chips
    /// (#162 — the chips pass `labels(applying:)`). A start still carrying a
    /// value-less label (`issue:`) is a fill-in-the-value-per-start workflow,
    /// so the created span opens straight into the row editor with that value
    /// field focused — copy a number, click the set, paste (#149). Fully-
    /// valued starts keep the fire-and-forget behaviour. The flag is raised
    /// before `beginEditing` claims the session, so it's in place whenever
    /// the editor's appearance consumes it.
    private func quickStart(labels: [SpanLabel]) async {
        guard let created = await model.start(tags: labels) else { return }
        if labels.contains(where: { $0.value.isEmpty }) {
            wantsValueFocusOnEditorAppear = true
            await model.beginEditing(created)
        }
    }

    /// Hover intent for a quick-start row: expansion waits until the pointer
    /// has rested on the row briefly, then animates in — so passing through
    /// the list never reflows it, and rows below slide rather than jump when
    /// one does expand. Collapse is immediate (but animated) on exit.
    private func rowHovered(_ set: TagSet, inside: Bool) {
        if inside {
            guard hoveredQuickStartID != set.id, pendingHoverID != set.id else { return }
            hoverIntentTask?.cancel()
            pendingHoverID = set.id
            hoverIntentTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                pendingHoverID = nil
                withAnimation(.snappy(duration: 0.18)) { hoveredQuickStartID = set.id }
            }
        } else {
            if pendingHoverID == set.id {
                hoverIntentTask?.cancel()
                pendingHoverID = nil
            }
            if hoveredQuickStartID == set.id {
                withAnimation(.spring(duration: 0.25)) { hoveredQuickStartID = nil }
            }
        }
    }

    @ViewBuilder
    private var activeTimerSection: some View {
        if !model.activeTimers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.activeTimers) { timer in
                    runningRow(timer)
                }
            }
        }

        // Ad-hoc start with no tags — capture time first, classify it in the
        // row editor while the clock runs. Available even while timers run:
        // the blank timespan starts alongside them.
        Button {
            Task {
                if let created = await model.start(tags: []) {
                    await model.beginEditing(created)
                }
            }
        } label: {
            Label("Start blank timer", systemImage: "circle.dashed")
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(model.isBusy)
    }

    /// One running timespan, uniform however many run: elapsed + tags, with
    /// edit (pencil) and stop (square) folded into the row. The pencil toggles
    /// an in-place editor for the row's tags and note.
    @ViewBuilder
    private func runningRow(_ timer: TimeSpan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.elapsedString(since: timer.start))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
            let tags = timer.labels
            if tags.isEmpty {
                Text("No marks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        TagPill(key: tag.key, value: tag.value,
                                color: model.tagColor(for: tag.key, value: tag.value))
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    if model.editSession?.spanID == timer.id {
                        await model.finishEditing()   // toggle-off saves, like Done
                    } else {
                        await model.beginEditing(timer)
                    }
                }
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Edit marks and note")
            Button {
                Task { await model.stop(id: timer.id) }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(HoverIconButtonStyle())
            .disabled(model.isBusy)
            .help("Stop")
        }
        if let session = model.editSession, session.spanID == timer.id {
            timerEditor(session)
        }
    }

    /// In-place editor for a running row — one line per tag (color swatch,
    /// key, value, remove), the add-label button, then the note, with
    /// Cancel / Done. The drafts are the shared session's; commits go through
    /// the model's one funnel (`commitEditSession`), which skips the
    /// round-trip when nothing changed (focus hops between fields hit this).
    private func timerEditor(_ session: SpanEditSession) -> some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 4) {
            ForEach($session.tagDrafts) { $tag in
                HStack(spacing: 6) {
                    // The popover gets its own anchored picker (#13); the
                    // system panel is unusable from a non-activating window
                    // (#142).
                    PopoverTagColorPicker(key: tag.key, value: tag.value)
                    TextField("key", text: $tag.key)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: LabelEditorStyle.compactKeyFieldWidth)
                        .focused($focusedField, equals: .key(tag.id))
                        .onSubmit { commit() }
                    Text(":").foregroundStyle(.secondary)
                    TextField("value", text: $tag.value)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .value(tag.id))
                        .onSubmit { commit() }
                    Button(role: .destructive) {
                        // Read the id before removeAll: `tag` is a binding
                        // into the same array, and reading it inside the
                        // predicate re-enters the array's exclusive access
                        // and traps.
                        let id = tag.id
                        session.tagDrafts.removeAll { $0.id == id }
                        commit()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear { editorRowHeight = geo.size.height }
                })
                // The grip hangs into the leading margin, half off the row,
                // instead of taking a column of these narrow rows. Reorders
                // persist through the same commit funnel as every other
                // popover edit.
                .overlay(alignment: .leading) {
                    GestureReorderGrip(tag: tag, rows: $session.tagDrafts,
                                       stride: editorRowHeight + 4) { commit() }
                        .offset(x: -18)
                }
            }
            Button {
                session.tagDrafts.append(TagRow())
            } label: {
                Label("Add Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            TextField("Add a note…", text: $session.noteDraft)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .note)
                .onSubmit { Task { await model.finishEditing() } }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelEditing() }
                    .buttonStyle(.borderless)
                Button("Done") { Task { await model.finishEditing() } }
                    .disabled(model.isBusy)
            }
        }
        .onChange(of: focusedField) { _, _ in commit() }
        .onAppear {
            // Consume a quick-start focus request (#149): aim at the first
            // value-less draft. Deferred a runloop hop — a @FocusState write
            // in the same pass that inserts the field can be dropped.
            guard wantsValueFocusOnEditorAppear else { return }
            wantsValueFocusOnEditorAppear = false
            guard let target = session.tagDrafts.first(where: {
                !$0.key.isEmpty && $0.value.isEmpty
            }) else { return }
            DispatchQueue.main.async { focusedField = .value(target.id) }
        }
    }

    private func commit() {
        Task { await model.commitEditSession() }
    }
}
