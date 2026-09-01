import SwiftUI

/// "Take me to this section of the app" — the seam that lets portable views
/// route without knowing what navigation looks like on their platform
/// (#124). The Mac injects a handler that fronts the settings window on the
/// right tab (SettingsWindowManager); the iOS root selects the matching tab
/// or presents the matching sheet. The default is a no-op so previews and
/// tests need no plumbing.
package struct OpenAppSectionAction {
    package var handler: (SettingsTab) -> Void

    package init(handler: @escaping (SettingsTab) -> Void) {
        self.handler = handler
    }

    package func callAsFunction(_ tab: SettingsTab) {
        handler(tab)
    }
}

extension EnvironmentValues {
    @Entry package var openAppSection = OpenAppSectionAction { _ in }

    /// Replay the onboarding tour — injected by shells that have one (the
    /// Mac's walkthrough window); Help hides its replay card when absent.
    @Entry package var replayTour: (() -> Void)? = nil
}
