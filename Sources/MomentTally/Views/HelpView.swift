import SwiftUI

/// The Help tab: a "Replay the tour" launcher up top (issue #192 — the
/// interactive walkthrough explains the app better than any of the prose
/// below it), then static copy explaining the data model and each surface of
/// the app, one collapsible card per section (first card open by default).
/// The subtleties documented here (key/value split, server-vs-local colours,
/// tag sets as launch presets, review rewrites bounded by the scan) otherwise
/// live only in code comments — keep the sections short and cheap to amend as
/// features change.
struct HelpView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ReplayTourCard {
                    OnboardingWindowManager.shared.show(model: model, replay: true)
                }
                ForEach(HelpSection.all) { section in
                    HelpSectionCard(section: section, isExpanded: binding(for: section.id))
                }
                AboutCard(isExpanded: binding(for: AboutCard.id))
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                if open { expanded.insert(id) } else { expanded.remove(id) }
            })
    }

    /// "1.2.0 (347)" from the bundle's Info.plist; a bare SwiftPM binary
    /// (`just run-dev`) has no bundle metadata and reads "dev". Fileprivate:
    /// the About card shows the same string.
    fileprivate static var versionString: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return "dev" }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// The tour launcher, dressed as the section cards below it so the tab stays
/// one visual list — but a one-click action, not a disclosure: the whole card
/// reopens the onboarding walkthrough in replay mode.
private struct ReplayTourCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .frame(width: 20)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn Moment Tally")
                        .font(Brand.script(16) ?? .headline)
                    Text("Get familiar with Moment Tally by re-playing the interactive Tour.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// One section as a card: a full-width clickable header (icon, title,
/// chevron) over the body, which is paragraphs — optionally interleaved with
/// a numbered rule list — shown only while expanded.
private struct HelpSectionCard: View {
    let section: HelpSection
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.tint)
                    Text(section.title)
                        // Brand script when bundled (sized up for its small
                        // x-height), the sans headline otherwise.
                        .font(Brand.script(16) ?? .headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    paragraphs(of: section.body)
                    if !section.rules.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(section.rules.enumerated()), id: \.offset) { index, rule in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.heading)
                                            .font(.callout.weight(.semibold))
                                        bodyText(rule.detail)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if let footer = section.footer {
                        paragraphs(of: footer)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 28)  // align body under the title, past the icon
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func paragraphs(of text: String) -> some View {
        ForEach(text.components(separatedBy: "\n\n"), id: \.self) { paragraph in
            bodyText(paragraph)
        }
    }

    /// `.init` so the string is parsed as markdown.
    private func bodyText(_ markdown: String) -> some View {
        Text(.init(markdown))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HelpSection: Identifiable {
    struct Rule {
        let heading: String
        let detail: String   // inline markdown
    }

    let title: String
    let symbol: String
    let body: String         // inline markdown; \n\n separates paragraphs
    var rules: [Rule] = []   // numbered list rendered between body and footer
    var footer: String? = nil
    var id: String { title }

    static let all: [HelpSection] = [
        HelpSection(
            title: "The data model",
            symbol: "cube",
            body: """
            Time is tracked as **moments**: a start, an end, an optional note, and any \
            number of marks. A *running* moment is one with no end yet — the menu-bar \
            clock counts it up. Overlaps are allowed, so several can run at once.

            A mark is a **key: value** pair on a moment, like `project: traggo`. Values \
            are free text; keys are lower-cased with spaces turned into “-”.

            Mark **keys** each carry a colour, stored with your moments in the local \
            database; recolouring a key changes it everywhere the key appears. *Colour \
            marks by value* (on by default; see Settings) additionally lets you pick a \
            colour per key: value pair, so moments differ by what they're about rather \
            than only by key.

            **Tallies** are named bundles of marks used to start moments with one \
            click, with a name and an icon. A moment started from a tally keeps the \
            marks but no link to the tally. Their order matters — the popover lists the \
            first few, in order (drag to reorder in Tallies). Marks have an order \
            too: drag them into place in any editor to control how a moment's pills \
            read.

            Everything above lives on this Mac by default. Connect a **sync server** \
            (see Settings) and it becomes yours-across-machines instead: moments, \
            key and value colours, tallies, and the two settings below all follow \
            your account to every connected Mac.
            """),
        HelpSection(
            title: "Choosing good marks",
            symbol: "tag",
            body: """
            Marks are the whole query model — every History chart, export filter, and \
            Mark Review pass works over the keys and values you pick, so the schema \
            is worth a minute of thought. Six rules cover it:
            """,
            rules: [
                Rule(
                    heading: "Mark what you'll query by",
                    detail: """
                    If you'd never group a chart or filter an export by it, it isn't \
                    a mark — put it in the note.
                    """),
                Rule(
                    heading: "Keep values from a small, stable vocabulary",
                    detail: """
                    Every distinct value is one more slice in every chart that groups \
                    by its key; one-off values (ticket titles, prose) turn a report \
                    back into a log.
                    """),
                Rule(
                    heading: "One fact per key",
                    detail: """
                    `project`, `deliverable`, and `type` as three keys filter and join \
                    independently; welded into one value they can only match whole.
                    """),
                Rule(
                    heading: "Pick key names once",
                    detail: """
                    `proj` on Mondays and `project` on Thursdays splits your history \
                    in two — every total silently misses whichever spelling you forget.
                    """),
                Rule(
                    heading: "Mirror systems you'll join against",
                    detail: """
                    To line time up with your invoices, calendar, or course catalogue, \
                    use that system's exact naming (`client: acme-inc`, not \
                    `client: acme`) — joins are literal.
                    """),
                Rule(
                    heading: "Decide what unmarked means",
                    detail: """
                    A moment with no `client` should mean something on purpose \
                    (internal? unbilled?), so gaps carry information instead of doubt.
                    """),
            ],
            footer: """
            A starter schema that covers most work: `project: wedding-shoot`, \
            `deliverable: album`, `type: editing`, `client: hartleys` — hours per \
            client, editing share per project, and moment-to-invoice joins, with no \
            hierarchy decided up front. Start smaller if in doubt: a key is easy to \
            add and painful to rename (though Mark Review can rescue a drifted \
            schema after the fact).

            The full guide, with worked examples of schemas going wrong, is at \
            [moment-tally.com/docs/marks](https://moment-tally.com/docs).
            """),
        HelpSection(
            title: "Pro-Moves: tally patterns that work",
            symbol: "sparkles",
            body: """
            Three shapes of tally cover most schemes people settle into — \
            worth stealing before inventing your own:
            """,
            rules: [
                Rule(
                    heading: "Quick marks only",
                    detail: """
                    A tally with *no* preset marks, just one chip per thing: a \
                    **Cooking** tally whose chips are `recipe: sourdough`, \
                    `recipe: focaccia`, `recipe: pad-thai`; a **Workout** tally with \
                    `activity: bike` / `run` / `yoga`; a **Reading** tally with a chip \
                    per book. Great for the simple stuff you do regularly — adding \
                    or retiring a chip never touches the time already tracked.
                    """),
                Rule(
                    heading: "Leave a value blank on purpose",
                    detail: """
                    A tally can carry a mark with an **empty value** — say an \
                    **Client Rebrand** tally pinning its `client:` and carrying a \
                    value-less `deliverable:`. Starting it opens the editor with \
                    that empty value focused: type the deliverable (or paste an \
                    invoice number) and the timer is already running. Perfect \
                    when the value changes too often for dedicated tallies, and \
                    the shared key links time across everything else.
                    """),
                Rule(
                    heading: "Scale out to clients and projects",
                    detail: """
                    One tally per engagement — `client: acme` + \
                    `project: rebrand` baked in, a value-less `deliverable:` \
                    to fill per start, and `type:` / `meeting:` quick marks on \
                    top. The same month then cuts cleanly by type × project, \
                    type × client, or meeting × client in History's combined \
                    view, so billing and meeting overhead fall out of the chart.
                    """),
            ]),
        HelpSection(
            title: "Start timers from the Launcher or Menu Bar",
            symbol: "menubar.arrow.up.rectangle",
            body: """
            Start counting time for any of your **Tallies** with one click.

            Hovering a tally expands its **quick marks** - useful for adding extra \
            dimensionality to your moments without extra effort.

            A _valueless_ Mark can be filled in by editing in the **Menu Bar** or \
            **Log** view.

            Re-order your tallies in the **Tallies** menu to change their display order.

            You can also limit the amount of menu bar tallies in **Settings**.
            """),
        HelpSection(
            title: "View and edit Moments in the Log view",
            symbol: "list.bullet.rectangle",
            body: """
            Click a row to edit in place — start and end (the arrows step by the minute)\
            marks, note — or delete it.

            A row whose mark combination matches no saved tally shows a **＋**: it \
            saves those marks as a new tally, so an ad-hoc moment you keep repeating is \
            one click from becoming a tally.
            """),
        HelpSection(
            title: "Graph your statistics in the History view",
            symbol: "chart.pie",
            body: """
            Two donut charts, each with its own **Group by**: a mark key (one slice per \
            value) or a tally (one slice per member mark), so two breakdowns of the \
            same window sit side by side. The bars below show each day — one stack per \
            donut when both are active.

            The **range picker** sets the charts' window: the displayed week (with the \
            usual ‹ Today › stepping), or a trailing window — last 30 or 90 days, \
            12 months, or all history.

            With two group-bys active, **Count marks** switches from counting them \
            *separately* to counting **in groups**: one combined donut whose slices are \
            the pairings that actually occurred. Group one side by `type` and the other \
            by `client` and the slices read type × client — swap either side to cut the \
            same time by type × project or meeting × client.
            """),
        HelpSection(
            title: "Review and Correct your Marks",
            symbol: "pencil.line",
            body: """
            The log view is great for fixing a single time span. However, sometimes you \
            might want to make sweeping changes.

            The 'Marks' section scans your recent moments (pick how far back) and lists \
            every tally key with its mark values and usage counts. Here you can quickly \
            spot typos, near-duplicates, and other inconsistencies and clean them up.

            You can rename a key or value, move values to another key, or shift-click \
            instances to drag just a subset.

            Cleanups are **staged, not immediate**.

            Staged changes collect at the bottom as red→green sentences where the \
            target spelling stays editable. \
            **Approve Changes** then rewrites the affected moments one by one, with \
            progress and cancel.

            Two boundaries to know: rewrites only touch the **scanned range** — moments \
            outside it keep their old marks (scan wider to catch them; approving again \
            after a failure or cancel safely picks up where it left off) — and \
            **running moments are never rewritten**; stop them first, then rescan.
            """),
    ]
}

// MARK: About Moment Tally (#115, PR #202)

/// The open-source components in this build, one entry per license text in
/// the resource bundle. The MAS variant's list omits Sparkle and
/// swift-argument-parser: that binary links no updater and bundles no CLI,
/// so their notices would credit code the user didn't receive. Internal (not
/// fileprivate) so the resource-drift test can see it.
struct Acknowledgement: Identifiable {
    let name: String
    let detail: String
    let license: String
    /// Filename (no extension) of the bundled license text.
    let resource: String

    var id: String { name }

    /// The full license text; nil only if this list and the resource bundle
    /// drift apart, which AcknowledgementTests pins.
    var licenseText: String? {
        Brand.resources.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static let all: [Acknowledgement] = {
        var all = [
            Acknowledgement(
                name: "GRDB.swift",
                detail: "the SQLite toolkit behind the local store",
                license: "MIT License",
                resource: "GRDB-MIT"),
        ]
        #if !MAS_BUILD
        all += [
            Acknowledgement(
                name: "Sparkle",
                detail: "the in-app update framework",
                license: "MIT License",
                resource: "Sparkle-MIT"),
            Acknowledgement(
                name: "swift-argument-parser",
                detail: "command parsing in the bundled moment-tally CLI",
                license: "Apache License 2.0",
                resource: "SwiftArgumentParser-Apache"),
        ]
        #endif
        return all
    }()
}

/// The About card: an About This Mac-style masthead — the gradient tally
/// motif and Morganite Pro wordmark at display size, centered with air
/// around them — over the maker/copyright lines, then the left-aligned
/// licensed-typeface attributions and open-source acknowledgements (a line
/// per component with its license text expandable underneath, so the
/// notices those licenses ask for ship inside the app rather than in a
/// file nobody finds).
struct AboutCard: View {
    static let id = "about"
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .frame(width: 20)
                        .foregroundStyle(.tint)
                    Text("About Moment Tally")
                        .font(Brand.script(16) ?? .headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    masthead
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            attribution("""
                            **Morganite Pro™** — used with permission from \
                            [Rajesh Kumar](https://www.behance.net/rajputrajesh).
                            """)
                            attribution("""
                            **Palm Springs** — used with permission from \
                            [Tom at Tropical Type](https://tropicaltype.com/).
                            """)
                        }
                        Text("Moment Tally builds on these open-source components.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(Acknowledgement.all) { AcknowledgementRow(item: $0) }
                    }
                    .padding(.leading, 28)  // align with the other cards' bodies
                }
                .padding(.top, 10)
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The mock's centered stack: motif, wordmark, version, then the by-line
    /// block. Point sizes leave the 384px motif and 256px wordmark renders
    /// ~3× headroom on Retina.
    private var masthead: some View {
        VStack(spacing: 0) {
            if let motif = Brand.motif(for: colorScheme) {
                Image(nsImage: motif)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 120)
                    .accessibilityHidden(true)  // decorative; the wordmark speaks
            }
            if let wordmark = Brand.wordmarkLockup(for: colorScheme) {
                Image(nsImage: wordmark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 64)
                    .accessibilityLabel("Moment Tally")
                    .padding(.top, 18)
            } else {
                Brand.wordmark(size: 34)
                    .padding(.top, 18)
            }
            Text("v\(HelpView.versionString)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, -1)
            VStack(spacing: 3) {
                Text("Moment Tally by Streetfortress Industries, LLC")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Copyright © 2026 Steven Fitzpatrick. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(.init("[www.streetfortress.com](https://www.streetfortress.com)"))
                    .font(.caption)
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// `.init` so the string is parsed as markdown (bold + links).
    private func attribution(_ markdown: String) -> some View {
        Text(.init(markdown))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Name and role on the left, the license name as a disclosure toggle on the
/// right; the full text unfolds beneath, selectable for copying.
private struct AcknowledgementRow: View {
    let item: Acknowledgement
    @State private var showsLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name)
                    .font(.callout.weight(.semibold))
                Text("— \(item.detail)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showsLicense.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(item.license)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showsLicense ? 90 : 0))
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            if showsLicense, let text = item.licenseText {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
