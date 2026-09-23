#if os(iOS)
import SwiftUI
import MomentTallyCore

/// What the regular-width canvas shows (#126, #286). Raw-string so the
/// selection persists via @SceneStorage.
enum RegularCanvas: String {
    /// The split: launcher column beside (or, in portrait, above) the Log.
    case launcher
    /// Full-canvas sections: the surfaces that read a whole window's worth
    /// of time and want the width — a 7-column week, a row of donuts.
    case calendar, history
}

/// The regular-width root (#126, per the settled #116 shape): the launcher
/// as a column with the section buttons *below* it (not a tab bar),
/// adjacent to a collapsible Log pane — the "at work" screen: start a
/// tally, see today's moments. Calendar and History are canvas sections
/// (#286 promoted Calendar out of the pane: a week grid squeezed into a
/// 340–520pt pane could never carry the day/week/month modes). The views
/// themselves are the portable ones every root shares; this file only
/// decides the arrangement. Compact width never sees it — the app root
/// falls back to the #124 TabView off the size class, which is also what
/// Slide Over / narrow Split View multitasking gets.
///
/// Portrait turns the split (#280): the launcher grid full-width on top,
/// the pane below it, in one screen-long scroll — scrolling down lets the
/// Log take the screen. Orientation is not a size class on iPad (regular ×
/// regular both ways), so the axis is keyed on geometry, width < height.
/// The unfolded iPhone Duo opens in portrait, so this is what it shows
/// first.
///
/// State lives above (persisted with @SceneStorage in MomentTallyRootView)
/// so `openAppSection` routes from anywhere — including sheets — land here.
struct IPadSplitRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    @Binding var canvas: RegularCanvas
    @Binding var paneCollapsed: Bool
    @State private var showReorder = false

    var body: some View {
        Group {
            switch canvas {
            case .launcher: splitView
            case .calendar: canvasView("Calendar") { CalendarView() }
            case .history: canvasView("History") { HistoryChartsView() }
            }
        }
        .sheet(isPresented: $showReorder) {
            IOSReorderSheet()
        }
        // Section hardware-keyboard shortcuts (#126/#59): ⌘1 the launcher
        // split, ⌘2 the Log pane, ⌘3 Calendar, ⌘4 History — the compact
        // tab order. Zero-opacity buttons rather than .hidden() — hidden
        // views drop out of the responder path, transparent ones keep
        // their shortcut.
        .overlay {
            Group {
                Button("") { canvas = .launcher }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { showLog() }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { canvas = .calendar }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { canvas = .history }
                    .keyboardShortcut("4", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func showLog() {
        canvas = .launcher
        withAnimation(.snappy) { paneCollapsed = false }
    }

    // MARK: Split canvas

    private var splitView: some View {
        GeometryReader { geo in
            if geo.size.width < geo.size.height {
                verticalCanvas(width: geo.size.width)
            } else {
                horizontalCanvas
            }
        }
    }

    /// Landscape: the launcher column beside the collapsible pane.
    private var horizontalCanvas: some View {
        HStack(spacing: 0) {
            launcherColumn
            if !paneCollapsed {
                Divider()
                paneView
                    .frame(minWidth: 340, idealWidth: 440, maxWidth: 520)
            }
        }
    }

    /// Portrait (#280): one scroll, not two. The launcher surface lays out
    /// at its natural height (no ScrollView of its own), the section
    /// buttons follow it as a compact row above the pane's divider so the
    /// pane header stays the visual boundary, and the Log's rows embed
    /// through `outerScroll` — its pinned day headers and the #130
    /// hand-off scroll both work against this scroll. The pane collapse
    /// has no meaning stacked, so neither chrome offers it here.
    private func verticalCanvas(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    titleRow(collapsible: false)
                    LauncherSurface(embeddedWidth: width)
                    sectionButtons
                    Divider()
                    VStack(spacing: 0) {
                        paneHeader(collapsible: false)
                        Divider()
                        paneContent
                    }
                    .background(.background.secondary)
                    .environment(\.outerScroll, proxy)
                }
            }
            .refreshable { await model.refresh() }
        }
    }

    private var launcherColumn: some View {
        VStack(spacing: 0) {
            titleRow(collapsible: true)
            LauncherSurface()
            Divider()
            sectionButtons
        }
    }

    private func titleRow(collapsible: Bool) -> some View {
        HStack {
            if let script = Brand.script(30) {
                Text("Moment Tally").font(script)
            } else {
                Brand.wordmark(size: 24)
            }
            Spacer()
            if collapsible {
                Button {
                    withAnimation(.snappy) { paneCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .accessibilityLabel(paneCollapsed ? "Show pane" : "Hide pane")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The routes a tab bar would carry, as plain buttons under the
    /// launcher — the #116 planning decision for the iPad shape.
    private var sectionButtons: some View {
        HStack(spacing: 4) {
            sectionButton("Calendar", icon: "calendar") { canvas = .calendar }
            sectionButton("History", icon: "chart.pie") { canvas = .history }
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

    // MARK: Log pane

    private var paneView: some View {
        VStack(spacing: 0) {
            paneHeader(collapsible: true)
            Divider()
            paneContent
        }
        .background(.background.secondary)
    }

    private func paneHeader(collapsible: Bool) -> some View {
        HStack {
            Text("Log")
                .font(.headline)
            Spacer()
            if collapsible {
                Button {
                    withAnimation(.snappy) { paneCollapsed = true }
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .accessibilityLabel("Hide pane")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var paneContent: some View {
        LogView()
    }

    // MARK: Canvas sections

    /// A full-screen section (#126): the view gets the whole canvas under
    /// an inline title, with the way back to the launcher leading.
    private func canvasView<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            canvas = .launcher
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
