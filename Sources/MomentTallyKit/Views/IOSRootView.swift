#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The iOS app's root: compact width gets the #124 TabView (launcher
/// first, parity views on the remaining tabs); regular width gets the
/// #126 split layout (launcher column + collapsible pane, full-canvas
/// History). Owns the `AppModel`, exactly like the Mac's `MomentTallyApp`.
///
/// The regular arrangement persists per scene (#126): which pane, whether
/// it's collapsed, and whether History owns the canvas.
public struct MomentTallyRootView: View {
    @State private var model = AppModel()
    @State private var selection: Pane = .launcher
    @State private var sheet: SheetRoute?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("regular.sidePane") private var sidePane: RegularSidePane = .log
    @SceneStorage("regular.paneCollapsed") private var paneCollapsed = false
    @SceneStorage("regular.historyCanvas") private var historyCanvas = false

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
                IPadSplitRoot(sidePane: $sidePane,
                              paneCollapsed: $paneCollapsed,
                              historyCanvas: $historyCanvas)
            } else {
                tabView
            }
        }
        .environment(model)
        .environment(\.openAppSection, OpenAppSectionAction { tab in
            open(tab)
        })
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
                historyCanvas = false
            case .log:
                historyCanvas = false
                sidePane = .log
                withAnimation(.snappy) { paneCollapsed = false }
            case .calendar:
                historyCanvas = false
                sidePane = .calendar
                withAnimation(.snappy) { paneCollapsed = false }
            case .history:
                historyCanvas = true
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
