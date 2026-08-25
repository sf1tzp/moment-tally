import SwiftUI
import MomentTallyCore

/// The first-run sequence (issue #93): Welcome (optionally connect a sync
/// server or import from Traggo) → interactive walkthrough of the mark model
/// (skippable), whose final pages create the user's first tallies → land
/// in the Tallies tab. Hosted by `OnboardingWindowManager`; the walkthrough
/// step itself lives in `WalkthroughView` with `WalkthroughModel` as its
/// shared dataset.
///
/// A replay (issue #192) is the same sequence minus the first-run parts:
/// no Welcome step (concepts and surfaces are the point, not connect/import),
/// a read-only tally page, and no Tallies tab on the way out.
struct OnboardingView: View {
    /// One shared fixed size — the window never resizes between steps.
    static let size = CGSize(width: 700, height: 560)

    private enum Step {
        case welcome, walkthrough
    }

    @Environment(AppModel.self) private var model
    @State private var step: Step
    @State private var walkthrough = WalkthroughModel()
    private let replay: Bool

    init(replay: Bool = false) {
        self.replay = replay
        _step = State(initialValue: replay ? .walkthrough : .welcome)
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStep(onContinue: { step = .walkthrough })
            case .walkthrough:
                WalkthroughView(
                    walkthrough: walkthrough,
                    replay: replay,
                    // A replay has no Welcome to go back to.
                    onBack: replay ? nil : { step = .welcome },
                    // The walkthrough is the whole remaining sequence — its
                    // Continue (and Skip Tour) ends onboarding.
                    onContinue: {
                        OnboardingWindowManager.shared.finish(openingTagSets: !replay)
                    })
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The window is .fullSizeContentView, so pad the top edge clear of
        // the floating traffic lights.
        .background(.background)
    }
}

// MARK: - Shared chrome

/// The fixed bottom bar every step ends with: optional Back, optional
/// secondary action, one prominent primary action.
struct OnboardingFooter<Secondary: View>: View {
    var back: (() -> Void)?
    var primaryTitle: String
    var primaryAction: () -> Void
    @ViewBuilder var secondary: Secondary

    var body: some View {
        HStack {
            if let back {
                Button("Back", action: back)
            }
            Spacer()
            secondary
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(20)
    }
}

extension OnboardingFooter where Secondary == EmptyView {
    init(back: (() -> Void)? = nil, primaryTitle: String,
         primaryAction: @escaping () -> Void) {
        self.init(back: back, primaryTitle: primaryTitle,
                  primaryAction: primaryAction) { EmptyView() }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The collapsed layout fits the fixed window with no scrollbar;
            // the scroll view is only overflow headroom for the cards'
            // disclosed forms.
            ScrollView {
                VStack(spacing: 0) {
                    // The masthead leads with the tagline, as on the website:
                    // the real-face lockup renders where bundled, the system
                    // stand-ins as fallback.
                    if let tagline = Brand.taglineLockup(for: colorScheme) {
                        Image(nsImage: tagline)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(height: 54)
                            .accessibilityLabel("Count what counts.")
                    } else {
                        Text("Count what counts.")
                            .font(Brand.promo(40))
                    }
                    Text("Mark the moments of your day and see where the effort goes")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)

                    // The welcome line
                        Text("Welcome to Moment Tally")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    .padding(.top, 56)

                    // The cards stay visible in demo mode, just disabled — the
                    // "a demo never reaches a real server" invariant holds via
                    // disabled controls, not hidden UI.
                    VStack(spacing: 10) {
                        if model.isDemo {
                            Label("Demo mode — running on seeded sample data; connections are disabled.",
                                  systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SyncConnectCard()
                        TraggoImportCard()
                        Text("Both are optional and live in Settings whenever you want them — everything works locally out of the box.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: 460)
                    .padding(.top, 12)
                }
                // Clear of the floating traffic lights (the window is
                // .fullSizeContentView) and roomy, per the website masthead.
                .padding(.top, 52)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            OnboardingFooter(primaryTitle: "Continue", primaryAction: onContinue)
        }
    }
}

/// Compact welcome-flavoured version of Settings' sync section: same model
/// calls, disclosure instead of a form.
private struct SyncConnectCard: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        WelcomeActionCard(title: Text("Connecting to a Moment Tally Server?"),
                          subtitle: "Sync moments, marks, and colors across your Macs.",
                          expanded: $expanded) {
            if let icon = Brand.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        } content: {
            if model.isDemo {
                Text("Disabled in demo mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let server = model.syncServer {
                Label("Connected to \(server.url)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Group {
                    TextField("Server URL", text: $url)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .onSubmit(connect)
                    HStack {
                        if model.isConnectingSync { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Connect", action: connect)
                            .disabled(url.isEmpty || username.isEmpty || password.isEmpty
                                || model.isConnectingSync)
                    }
                }
                .disabled(model.isDemo)
                if let error = model.syncConnectError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
        }
    }

    private func connect() {
        guard !url.isEmpty, !username.isEmpty, !password.isEmpty else { return }
        Task {
            await model.connectSyncServer(url: url, username: username, password: password)
            password = ""   // never keep the password around
        }
    }
}

/// Compact welcome-flavoured version of Settings' Traggo import section.
private struct TraggoImportCard: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        @Bindable var model = model
        WelcomeActionCard(title: Text("Coming from Traggo?"),
                          subtitle: "Copy a Traggo history — time spans, tags, and colors — into the local database.",
                          expanded: $expanded) {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
                .foregroundStyle(Brand.traggoBlue)
        } content: {
            if model.isDemo {
                Text("Disabled in demo mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                TextField("Server URL", text: $model.serverURL)
                    .autocorrectionDisabled()
                if model.hasTraggoSession {
                    Text("Using the saved Traggo sign-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                HStack {
                    if model.isImporting {
                        ProgressView().controlSize(.small)
                        Text("Imported \(model.importedSpanCount) moments…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import", action: runImport)
                        .disabled(model.isImporting
                            || (!model.hasTraggoSession && (username.isEmpty || password.isEmpty)))
                }
            }
            .disabled(model.isDemo)
            if let summary = model.importSummary {
                Label("Imported \(summary.spansImported) moments and \(summary.definitionsCreated + summary.definitionsRecolored) mark keys.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = model.importError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .tint(Brand.traggoBlue)
    }

    private func runImport() {
        Task {
            await model.importFromTraggo(username: username, password: password)
            password = ""   // never keep the password around
        }
    }
}

/// One optional setup row on the welcome step: an icon + title row that
/// discloses its form when clicked, in the style of app welcome screens.
/// `title` is a `Text` so cards can set brand segments (the wordmark); the
/// icon is a view for the same reason (the sync card shows the app mark).
private struct WelcomeActionCard<Icon: View, Content: View>: View {
    let title: Text
    let subtitle: String
    @Binding var expanded: Bool
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 12) {
                    icon
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        title.font(.body.weight(.medium))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.leading, 40)
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}
