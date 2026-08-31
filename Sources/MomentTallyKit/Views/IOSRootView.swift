#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The iOS app's root (#124): the launcher as the first tab of a TabView —
/// the navigation shape settled with #125 in mind — with Log / Calendar /
/// History tabs stubbed until view parity (#125) fills them in. Owns the
/// `AppModel`, exactly like the Mac's `MomentTallyApp`.
public struct MomentTallyRootView: View {
    @State private var model = AppModel()
    @State private var selection: Pane = .launcher
    @State private var sheet: SheetRoute?

    private enum Pane: Hashable {
        case launcher, log, calendar, history
    }

    /// Sections with no tab of their own yet: they present as sheets. Real
    /// content lands with #125 (Tallies editor, Review, Help, Settings).
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
            placeholder("Log", icon: "list.bullet.rectangle")
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                .tag(Pane.log)
            placeholder("Calendar", icon: "calendar")
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Pane.calendar)
            placeholder("History", icon: "chart.pie")
                .tabItem { Label("History", systemImage: "chart.pie") }
                .tag(Pane.history)
        }
        .environment(model)
        .environment(\.openAppSection, OpenAppSectionAction { tab in
            open(tab)
        })
        .sheet(item: $sheet) { route in
            NavigationStack {
                ContentUnavailableView {
                    Label(route.title, systemImage: "hammer")
                } description: {
                    Text("Arrives with iOS view parity — issue #125.")
                }
                .navigationTitle(route.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { sheet = nil }
                    }
                }
            }
            .presentationDetents([.medium])
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

    private func placeholder(_ title: String, icon: String) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text("Arrives with iOS view parity — issue #125.")
            }
            .navigationTitle(title)
        }
    }
}
#endif
