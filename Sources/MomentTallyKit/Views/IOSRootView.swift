#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The iOS app's root: compact width gets the #124 TabView (launcher
/// first, parity views on the remaining tabs); regular width gets the
/// #126 split layout (launcher column + collapsible Log pane, with
/// Calendar and History as full-canvas sections). Owns the `AppModel`,
/// exactly like the Mac's `MomentTallyApp`.
///
/// The regular arrangement persists per scene (#126): what the canvas
/// shows and whether the Log pane is collapsed.
public struct MomentTallyRootView: View {
    @State private var model = AppModel()
    @State private var selection: Pane = .launcher
    @State private var sheet: SheetRoute?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("regular.paneCollapsed") private var paneCollapsed = false
    @SceneStorage("regular.canvas") private var canvas: RegularCanvas = .launcher

    private enum Pane: Hashable {
        case launcher, log, calendar, history
    }

    /// Sections with no tab of their own: they present as sheets over
    /// whichever tab is up (#125).
    private enum SheetRoute: String, Identifiable {
        case tagSets, review, help, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .tagSets: "Tallies"
            case .review: "Review"
            case .help: "Help"
            case .settings: "Settings"
            }
        }
    }

    public init() {}

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                IPadSplitRoot(canvas: $canvas, paneCollapsed: $paneCollapsed)
            } else {
                tabView
            }
        }
        .environment(model)
        .environment(\.openAppSection, OpenAppSectionAction { tab in
            open(tab)
        })
        // iOS has no long-lived background process (#317): the only sync
        // triggers are the launch kick and the 60 s loop while
        // foregrounded, so an edit made on the Mac while the phone slept
        // is stale until the next tick. Pull on every return to the
        // foreground; pushes (#243) are the latency optimization on top,
        // never the floor. A no-op when sync is off (cloudSync is nil).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.cloudSync?.kick(after: 0) }
        }
        .sheet(item: $sheet) { route in
            sheetContent(route)
                .environment(model)
                .environment(\.openAppSection, OpenAppSectionAction { tab in
                    // A section chosen from inside a sheet (Log ＋ → Tallies,
                    // Review → Log) lands on its tab/pane, not on top.
                    sheet = nil
                    open(tab)
                })
        }
    }

    private var tabView: some View {
        TabView(selection: $selection) {
            IOSLauncherHome()
                .tabItem { Label("Launch", systemImage: "square.grid.2x2") }
                .tag(Pane.launcher)
            NavigationStack {
                LogView()
                    .navigationTitle("Log")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            .tag(Pane.log)
            NavigationStack {
                CalendarView()
                    .navigationTitle("Calendar")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(Pane.calendar)
            NavigationStack {
                HistoryChartsView()
                    .navigationTitle("History")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("History", systemImage: "chart.pie") }
            .tag(Pane.history)
        }
    }

    /// The sheet-presented sections. TagSetsSettingsView brings its own
    /// NavigationStack (it pushes the detail editor); the rest get one here
    /// with an explicit Done.
    @ViewBuilder
    private func sheetContent(_ route: SheetRoute) -> some View {
        switch route {
        case .tagSets:
            TagSetsSettingsView()
        case .review:
            NavigationStack {
                TagReviewView()
                    .navigationTitle("Review")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { sheet = nil }
                        }
                    }
            }
        case .help:
            NavigationStack {
                HelpView()
                    .navigationTitle("Help")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { sheet = nil }
                        }
                    }
            }
        case .settings:
            NavigationStack {
                GeneralSettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { sheet = nil }
                        }
                    }
            }
        }
    }

    /// The portable views' navigation seam — tabs/sheets in compact,
    /// panes/canvas/sheets in regular.
    private func open(_ tab: SettingsTab) {
        if horizontalSizeClass == .regular {
            switch tab {
            case .launcher:
                canvas = .launcher
            case .log:
                canvas = .launcher
                withAnimation(.snappy) { paneCollapsed = false }
            case .calendar:
                canvas = .calendar
            case .history:
                canvas = .history
            case .tagSets: sheet = .tagSets
            case .review: sheet = .review
            case .help: sheet = .help
            case .settings: sheet = .settings
            }
        } else {
            switch tab {
            case .launcher: selection = .launcher
            case .log: selection = .log
            case .calendar: selection = .calendar
            case .history: selection = .history
            case .tagSets: sheet = .tagSets
            case .review: sheet = .review
            case .help: sheet = .help
            case .settings: sheet = .settings
            }
        }
    }

}
#endif
