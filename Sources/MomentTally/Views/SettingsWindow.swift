import SwiftUI
import AppKit
import MomentTallyKit

/// Owns the settings window and reuses a single instance. Modelled on
/// Rectangle's preferences window: a toolbar-style `NSTabViewController` with an
/// icon per section, each section a SwiftUI view hosted in an `NSHostingController`.
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var windowController: NSWindowController?
    private var tabController: NSTabViewController?

    private override init() {}

    func show(model: AppModel, tab: SettingsTab = .settings) {
        if windowController == nil {
            windowController = makeWindowController(model: model)
        }
        tabController?.selectedTabViewItemIndex = tab.rawValue
        // An .accessory app isn't active when the menu is clicked, so activate
        // and order front or the window opens behind the focused app.
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindowController(model: AppModel) -> NSWindowController {
        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar

        // Every section shares one window size, so the window opens the same
        // regardless of which menu shortcut was used and never clips a tab.
        let size = NSSize(width: 780, height: 560)

        tabController.addTabViewItem(item("Launcher", symbol: "square.grid.2x2",
                                          content: LauncherView(), model: model, size: size))
        // The brand mark rather than an SF Symbol. The toolbar rescales it to
        // its own icon box whatever `size` says, so `inset` is what tunes how
        // big it reads against the symbols either side — this is the dial to
        // turn, not the size.
        tabController.addTabViewItem(item("Tallies", image: Brand.tallyMark(size: 18, inset: Brand.symbolInset),
                                          content: TagSetsSettingsView(), model: model, size: size))
        tabController.addTabViewItem(item("Log", symbol: "list.bullet.rectangle",
                                          content: LogView(), model: model, size: size))
        tabController.addTabViewItem(item("Calendar", symbol: "calendar",
                                          content: CalendarView(), model: model, size: size))
        tabController.addTabViewItem(item("History", symbol: "chart.pie",
                                          content: HistoryChartsView(), model: model, size: size))
        tabController.addTabViewItem(item("Marks", symbol: "pencil.line",
                                          content: TagReviewView(), model: model, size: size))
        tabController.addTabViewItem(item("Help", symbol: "questionmark.circle",
                                          content: HelpView(), model: model, size: size))
        tabController.addTabViewItem(item("Settings", symbol: "gear",
                                          content: GeneralSettingsView(), model: model, size: size))

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference          // centred, System-Settings layout
        window.titlebarSeparatorStyle = .none       // no line under the toolbar
        window.isReleasedWhenClosed = false         // we reuse the controller
        // NSWindow(contentViewController:) doesn't reliably adopt the selected
        // pane's fitting size, so pin the content size to the shared pane size.
        window.setContentSize(size)
        window.center()
        window.delegate = self

        self.tabController = tabController
        return NSWindowController(window: window)
    }

    /// The panel follows the window that opened it (#142): swatches in the
    /// settings tabs front the shared color panel, and letting it outlive
    /// the window strands it hidden once the app deactivates.
    func windowWillClose(_ notification: Notification) {
        NSColorPanel.closeShared()
    }

    private func item(_ label: String, symbol: String,
                      content: some View, model: AppModel, size: NSSize) -> NSTabViewItem {
        item(label, image: NSImage(systemSymbolName: symbol, accessibilityDescription: label),
             content: content, model: model, size: size)
    }

    private func item(_ label: String, image: NSImage?,
                      content: some View, model: AppModel, size: NSSize) -> NSTabViewItem {
        // Fixed frame per section so the window sizes itself to the selection
        // rather than to whatever SwiftUI proposes.
        let host = NSHostingController(rootView:
            AnyView(content.environment(model)
                .environment(MacShell.updater)
                .environment(MacShell.loginItem)
                // Portable views (LauncherView) route sections through this
                // seam; on the Mac that means switching this window's tab.
                .environment(\.openAppSection, OpenAppSectionAction { [weak self] tab in
                    self?.show(model: model, tab: tab)
                })
                .frame(width: size.width, height: size.height)))
        // In `.toolbar` style the window title follows the selected controller's
        // `title`. Give every section the same title so it stays static (an
        // unset title would show "Untitled" when switching tabs).
        host.title = "Moment Tally"
        let item = NSTabViewItem(viewController: host)
        item.label = label
        image?.accessibilityDescription = label
        item.image = image
        return item
    }
}
