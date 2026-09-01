#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The iOS app's root (#124/#125): the launcher as the first tab of a
/// TabView, with the parity views (#125) on the remaining tabs and the
/// section sheets. Owns the `AppModel`, exactly like the Mac's
/// `MomentTallyApp`.
public struct MomentTallyRootView: View {
    @State private var model = AppModel()
    @State private var selection: Pane = .launcher
    @State private var sheet: SheetRoute?

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
        .environment(model)
        .environment(\.openAppSection, OpenAppSectionAction { tab in
            open(tab)
        })
        .sheet(item: $sheet) { route in
            sheetContent(route)
                .environment(model)
                .environment(\.openAppSection, OpenAppSectionAction { tab in
                    // A section chosen from inside a sheet (Log ＋ → Tallies,
                    // Review → Log) lands on its tab/sheet, not on top.
                    sheet = nil
                    open(tab)
                })
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

    /// The portable views' navigation seam, mapped onto tabs and sheets.
    private func open(_ tab: SettingsTab) {
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
#endif
