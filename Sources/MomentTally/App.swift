import SwiftUI
import AppKit
import MomentTallyKit

/// The Mac shell's own observable models — auto-update and Start at Login
/// are app-shell concerns with no iOS analogue, so they live beside
/// `AppModel` rather than inside it (#124) and ride the environment into
/// every window (see also SettingsWindowManager.item).
@MainActor
enum MacShell {
    static let updater = UpdaterModel()
    static let loginItem = LoginItemModel()
}

@main
struct MomentTallyApp: App {
    // An AppDelegate is the cleanest place to set the activation policy so the
    // app lives only in the menu bar (no Dock icon, no app-switcher entry).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The single source of truth for the whole app. @State owns the @Observable
    // object; SwiftUI keeps it alive for the app's lifetime.
    @State private var model = AppModel()

    init() {
        // Licensed brand fonts ride in Contents/Resources/Fonts when the
        // build machine had the private checkout (see bundle-app.sh);
        // register them before any view resolves Brand.script.
        Brand.registerFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .environment(MacShell.updater)
                .environment(MacShell.loginItem)
                .frame(width: 300)
        } label: {
            // The menu-bar label is reactive: when `activeTimer` changes (or the
            // per-second tick fires) this closure re-renders with the new elapsed
            // time. When idle we just show an icon.
            Group {
                if let label = model.menuBarLabel {
                    Text(label)
                } else {
                    Image(nsImage: Brand.menuBarIcon)
                }
            }
            // The label is the only view alive from launch (the popover exists
            // only while open), so it hosts the first-run hook. `.task` fires
            // once the label appears, safely after the app finishes launching.
            .task { OnboardingWindowManager.shared.showIfNeeded(model: model) }
        }
        .menuBarExtraStyle(.window) // a real SwiftUI panel, not a plain NSMenu

        // The settings window is a toolbar-style NSTabViewController (see
        // SettingsWindowManager), opened from the menu — not a SwiftUI scene,
        // so that it matches the native System-Settings look with per-section
        // toolbar icons.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = agent app: menu-bar only, no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
