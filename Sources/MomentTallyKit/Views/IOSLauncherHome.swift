#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The iPhone home surface (#124): the menu-bar popover's job — running
/// timers, quick start, ad-hoc blank timer — done with touch idioms, not a
/// port of the popover chrome. The card grid is the popover's Launcher grid
/// re-columned for compact width; hover affordances become always-visible
/// controls (stop button on running rows, persistent stop scrim on running
/// cards) or long-press (quick-label chips).
package struct IOSLauncherHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    @State private var showReorder = false

    private static let minCardWidth: CGFloat = 150
    private static let spacing: CGFloat = 12

    package init() {}

    package var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let content = geo.size.width - Self.spacing * 2
                let columns = max(1, Int((content + Self.spacing)
                                         / (Self.minCardWidth + Self.spacing)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        runningSection
                        quickStartSection(columns: columns)
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(Self.spacing)
                }
            }
            .navigationTitle("Moment Tally")
            .toolbar {
                // Palm Springs when the build carries the injected fonts —
                // same degrade-to-system rule as everywhere else.
                if let script = Brand.script(26) {
                    ToolbarItem(placement: .principal) {
                        Text("Moment Tally").font(script)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showReorder = true
                        } label: {
                            Label("Reorder Tallies", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(model.tagSets.count < 2)
                        Divider()
                        Button {
                            openAppSection(.tagSets)
                        } label: {
                            Label("Tallies", systemImage: "square.grid.2x2")
                        }
                        Button {
                            openAppSection(.review)
                        } label: {
                            Label("Review", systemImage: "checklist")
                        }
                        Button {
                            openAppSection(.help)
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
                        }
                        Button {
                            openAppSection(.settings)
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showReorder) {
                IOSReorderSheet()
            }
            // The one shared edit session, as a sheet: tap a running row to
            // open it; dismissing by swipe commits, like the popover closing
            // (#70's "drafts must survive teardown" lesson — commits go
            // through the model's one funnel either way).
            .sheet(isPresented: Binding(
                get: { model.editSession != nil },
                set: { shown in
                    if !shown, model.editSession != nil {
                        Task { await model.finishEditing() }
                    }
                }
            )) {
                IOSSpanEditorSheet()
                    .presentationDetents([.medium, .large])
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
        }
    }

    // MARK: Running

    @ViewBuilder
    private var runningSection: some View {
        if !model.activeTimers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Running")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(model.activeTimers) { timer in
                    runningRow(timer)
                }
            }
        }

        // Ad-hoc start with no marks — capture time first, classify in the
        // editor while the clock runs. The created span opens straight into
        // the editor, same as the Mac popover's blank-timer row.
        Button {
            Task {
                if let created = await model.start(tags: []) {
                    await model.beginEditing(created)
                }
            }
        } label: {
            Label("Start blank timer", systemImage: "circle.dashed")
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    /// One running timespan: elapsed + marks, tap anywhere to edit, with an
    /// always-visible stop button — the popover folds stop/edit into
    /// hover-revealed icons; touch gets standing controls (#124).
    private func runningRow(_ timer: TimeSpan) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.beginEditing(timer) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.elapsedString(since: timer.start))
                        .font(.title3.monospacedDigit())
                    if timer.labels.isEmpty {
                        Text("No marks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(timer.labels, id: \.self) { tag in
                                TagPill(key: tag.key, value: tag.value,
                                        color: model.tagColor(for: tag.key,
                                                              value: tag.value))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.stop(id: timer.id) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .disabled(model.isBusy)
            .accessibilityLabel("Stop")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.fill.tertiary))
    }

    // MARK: Quick start

    private func quickStartSection(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.tagSets.isEmpty {
                ContentUnavailableView {
                    Label("No tallies yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("A tally is a one-tap timer for something you do often.")
                } actions: {
                    Button("Create a tally") {
                        model.newTagSet()
                        openAppSection(.tagSets)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Self.spacing),
                                         count: columns),
                          spacing: Self.spacing) {
                    ForEach(model.tagSets) { set in
                        TagSetCard(set: set)
                    }
                }
            }
        }
    }
}

/// Reorder as an explicit mode (#124): the Mac grid's live drag-reorder
/// fights touch scrolling, so iOS gets a native edit-mode list instead —
/// the same one shared order (there is deliberately no launcher-only
/// order), written back through the model on every move.
package struct IOSReorderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    package init() {}

    package var body: some View {
        NavigationStack {
            List {
                ForEach(model.tagSets) { set in
                    HStack(spacing: 12) {
                        LauncherTileIcon(set: set, size: 28)
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                    }
                }
                .onMove { from, to in
                    var sets = model.tagSets
                    sets.move(fromOffsets: from, toOffset: to)
                    model.tagSets = sets
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Tallies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
