import SwiftUI
import AppKit

/// Owns the first-run "Welcome to Moment Tally" window (issue #93): a fixed-size,
/// mac-app-like sheetless welcome sequence — Welcome → interactive walkthrough
/// (which ends by creating starter label sets) — shown once on a fresh install
/// and on every demo launch (the demo defaults suite is wiped per launch, so
/// the flag is always unset there).
///
/// The same window also replays on demand (issue #192, `replay: true`, from
/// Help): straight into the walkthrough, with the tally-creation page made
/// read-only so a configured account can't collect duplicates.
///
/// Set MOMENTTALLY_ONBOARDING=1 to force it regardless of the flag, for
/// development and screenshots.
@MainActor
final class OnboardingWindowManager: NSObject {
    static let shared = OnboardingWindowManager()
    private var windowController: NSWindowController?
    private weak var model: AppModel?

    private override init() {}

    func showIfNeeded(model: AppModel) {
        let forced = ProcessInfo.processInfo.environment["MOMENTTALLY_ONBOARDING"] == "1"
        guard forced || !model.hasCompletedOnboarding else { return }
        show(model: model)
    }

    func show(model: AppModel, replay: Bool = false) {
        self.model = model
        // A window that's already up keeps its mode — show just fronts it.
        if windowController == nil {
            let host = NSHostingController(rootView: OnboardingView(replay: replay).environment(model))
            let window = NSWindow(contentViewController: host)
            // Titled-but-chromeless, like macOS app welcome windows: the
            // close button floats over the content, which draws edge to edge.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: OnboardingView.size.width,
                                         height: OnboardingView.size.height))
            window.center()
            window.delegate = self
            windowController = NSWindowController(window: window)
        }
        // An .accessory app isn't active at launch; without activating, the
        // welcome window would open behind whatever has focus.
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// The sequence's terminal action: remember it ran, close, and land the
    /// user in the Label Sets tab next to whatever starter sets they picked.
    func finish(openingTagSets: Bool) {
        let model = model
        windowController?.window?.close()   // windowWillClose does the bookkeeping
        if openingTagSets, let model {
            SettingsWindowManager.shared.show(model: model, tab: .tagSets)
        }
    }
}

extension OnboardingWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as done — seen once, never nag again.
        model?.hasCompletedOnboarding = true
        // Drop the controller so a later show() starts a fresh sequence.
        windowController = nil
        // The walkthrough's colour swatches front the shared colour panel;
        // it follows its window (#142).
        NSColorPanel.closeShared()
    }
}
