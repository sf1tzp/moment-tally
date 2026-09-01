import SwiftUI
import MomentTallyKit

/// The Mac shell's own settings sections — Start at Login (#169) and Sparkle
/// (#46) — passed into the kit's `GeneralSettingsView` as trailing content:
/// their models are shell types the kit cannot see, and neither concern has
/// an iOS analogue (#125).
struct MacSettingsSections: View {
    @Environment(UpdaterModel.self) private var appUpdater
    @Environment(LoginItemModel.self) private var appLoginItem

    var body: some View {
        // Start at Login (#169). Absent from dev builds and demos, where
        // there is no bundle to register — see LoginItemModel.
        if appLoginItem.isAvailable {
            @Bindable var loginItem = appLoginItem
            Section("Login") {
                Toggle("Start Moment Tally at login", isOn: $loginItem.startsAtLogin)
                if loginItem.requiresApproval {
                    // Switched off behind the app's back — only System
                    // Settings can turn it back on.
                    HStack {
                        Text("Switched off in System Settings › Login Items. Turn it back on there — the toggle above can’t override it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                } else {
                    Text("Opens Moment Tally in the menu bar when you log in to this Mac. A per-Mac setting — it doesn’t sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        }
        // Sparkle (#46). Absent from dev builds and demos, where there is no
        // updater to configure.
        if appUpdater.isAvailable {
            @Bindable var updater = appUpdater
            Section("Updates") {
                Toggle("Check for updates in the background",
                       isOn: $updater.automaticallyChecksForUpdates)
                Text("Checks about once a day and offers new versions when they appear. Off means updates only come from “Check for Updates…” in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
