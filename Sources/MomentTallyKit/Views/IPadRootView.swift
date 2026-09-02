#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The regular-width side pane's content choices (#126). Raw-string so the
/// selection persists via @SceneStorage.
enum RegularSidePane: String {
    case log, calendar
}

/// The regular-width root (#126, per the settled #116 shape): the launcher
/// as a column with the section buttons *below* it (not a tab bar),
/// adjacent to a collapsible Log-or-Calendar pane; History takes the whole
/// canvas when selected. Compact width never sees this view — the app root
/// falls back to the #124 TabView off the size class, which is also what
/// Slide Over / narrow Split View multitasking gets.
///
/// State lives above (persisted with @SceneStorage in MomentTallyRootView)
/// so `openAppSection` routes from anywhere — including sheets — land here.
struct IPadSplitRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    @Binding var sidePane: RegularSidePane
    @Binding var paneCollapsed: Bool
    @Binding var historyCanvas: Bool
    @State private var showReorder = false

    var body: some View {
        Group {
            if historyCanvas {
                historyView
            } else {
                splitView
            }
        }
        .sheet(isPresented: $showReorder) {
            IOSReorderSheet()
        }
        // Pane-switching hardware-keyboard shortcuts (#126/#59): ⌘1 the
        // launcher canvas, ⌘2/⌘3 the Log/Calendar pane, ⌘4 History.
        // Zero-opacity buttons rather than .hidden() — hidden views drop
        // out of the responder path, transparent ones keep their shortcut.
        .overlay {
            Group {
                Button("") { historyCanvas = false }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { showPane(.log) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { showPane(.calendar) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { historyCanvas = true }
                    .keyboardShortcut("4", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func showPane(_ pane: RegularSidePane) {
        historyCanvas = false
        sidePane = pane
        withAnimation(.snappy) { paneCollapsed = false }
    }

    // MARK: Split canvas

    private var splitView: some View {
        HStack(spacing: 0) {
            launcherColumn
            if !paneCollapsed {
                Divider()
                paneView
                    .frame(minWidth: 340, idealWidth: 440, maxWidth: 520)
            }
        }
    }

    private var launcherColumn: some View {
        VStack(spacing: 0) {
            HStack {
                if let script = Brand.script(30) {
                    Text("Moment Tally").font(script)
                } else {
                    Brand.wordmark(size: 24)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { paneCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .accessibilityLabel(paneCollapsed ? "Show pane" : "Hide pane")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            LauncherSurface()
            Divider()
            sectionButtons
        }
    }

    /// The routes a tab bar would carry, as plain buttons under the
    /// launcher — the #116 planning decision for the iPad shape.
    private var sectionButtons: some View {
        HStack(spacing: 4) {
            sectionButton("History", icon: "chart.pie") { historyCanvas = true }
            sectionButton("Tallies", icon: "square.grid.2x2") { openAppSection(.tagSets) }
            sectionButton("Review", icon: "checklist") { openAppSection(.review) }
            sectionButton("Reorder", icon: "arrow.up.arrow.down") { showReorder = true }
                .disabled(model.tagSets.count < 2)
            sectionButton("Help", icon: "questionmark.circle") { openAppSection(.help) }
            sectionButton("Settings", icon: "gear") { openAppSection(.settings) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func sectionButton(_ title: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: Side pane

    private var paneView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Pane", selection: $sidePane) {
                    Text("Log").tag(RegularSidePane.log)
                    Text("Calendar").tag(RegularSidePane.calendar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                Button {
                    withAnimation(.snappy) { paneCollapsed = true }
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .accessibilityLabel("Hide pane")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch sidePane {
            case .log: LogView()
            case .calendar: CalendarView()
            }
        }
        .background(.background.secondary)
    }

    // MARK: History canvas

    /// Full-screen History (#126): the charts get the whole canvas.
    private var historyView: some View {
        NavigationStack {
            HistoryChartsView()
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            historyCanvas = false
                        } label: {
                            Label("Launcher", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
        }
    }
}
#endif
