import AppKit
import Foundation
import Observation
import MomentTallyCore
import MomentTallyKit
import ServiceManagement

/// Start at Login (#169), via `SMAppService.mainApp`: the app registers its
/// own bundle as a login item, no helper app or Info.plist entry needed, and
/// the registration follows the bundle if the user moves it. macOS keeps the
/// user in charge — the item appears in System Settings › General › Login
/// Items, where it can be switched off behind the app's back, so the toggle
/// re-reads the live status whenever the app comes to the front rather than
/// trusting a stored preference. Per-Mac by nature; deliberately not synced.
///
/// Like the updater, this only comes alive when running from an installed
/// .app bundle: an unbundled dev build (`swift build` + run) would register
/// its transient `.build` path as the login item. Demo mode (#39) stays off
/// too — a demo session must not touch the real login-item registration.
/// When off, the Settings section hides itself via `isAvailable`.
@MainActor
@Observable
final class LoginItemModel {
    let isAvailable: Bool

    /// `SMAppService.mainApp.status`, mirrored into observation. Reads as
    /// enabled only for `.enabled`; `.requiresApproval` (switched off in
    /// System Settings) renders the toggle off plus the explanation below.
    private(set) var status: SMAppService.Status = .notRegistered

    /// Why the last register/unregister failed, for the Settings caption;
    /// cleared by the next successful flip.
    private(set) var lastError: String?

    /// Whether the user disabled the item in System Settings — the one state
    /// the app can't leave by itself, so Settings pairs the toggle with an
    /// "open System Settings" escape hatch.
    var requiresApproval: Bool { status == .requiresApproval }

    /// The Settings toggle's binding. Setting it registers/unregisters and
    /// then re-reads the status, so the toggle always shows the system's
    /// answer, not the request.
    var startsAtLogin: Bool {
        get { status == .enabled }
        set {
            guard isAvailable else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(demo: Bool = DemoMode.isActive) {
        isAvailable = Bundle.main.bundlePath.hasSuffix(".app") && !demo
        guard isAvailable else { return }
        refresh()
        // The status can change while the app is running — System Settings,
        // or an approval granted after `.requiresApproval` — so re-read it
        // whenever the app comes back to the front (which opening the
        // Settings window does).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Open System Settings on the Login Items pane, for the
    /// `.requiresApproval` escape hatch.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refresh() {
        status = SMAppService.mainApp.status
    }
}
