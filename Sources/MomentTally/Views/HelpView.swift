import SwiftUI

/// The Help tab: static copy explaining the data model and each surface of
/// the app, one collapsible card per section (first card open by default).
/// The subtleties documented here (key/value split, server-vs-local colours,
/// tag sets as launch presets, review rewrites bounded by the scan) otherwise
/// live only in code comments — keep the sections short and cheap to amend as
/// features change.
struct HelpView: View {
    @State private var expanded: Set<String> = [HelpSection.all[0].id]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
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
            [momenttally.com/docs/marks](https://momenttally.com/docs/marks).
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
            title: "Menu bar popover",
            symbol: "menubar.arrow.up.rectangle",
            body: """
            The top section lists every **running moment**: elapsed time, marks, a \
            pencil that edits its marks and note in place, and a square stop button. \
            **Start blank timer** begins an unmarked moment — alongside anything \
            already running — and opens its editor so you can describe the time while \
            it runs.

            **Quick start** shows your tallies, capped to the first N (set the cap in \
            Settings; “N more…” opens the Launcher). A tally whose exact marks are \
            currently running is hidden until that moment stops. While a timer runs \
            the other rows grey out, but each keeps an enabled **＋** that starts the \
            tally *alongside* the running timer.

            Hovering a tally expands its **quick marks** — chips that ride along on \
            start, replacing the tally's value for the same key. Starting a tally (or \
            chip) that leaves a mark's value **blank** still starts the timer, and \
            opens its editor with that empty value focused — paste an issue number \
            or type the feature, no extra clicking.
            """),
        HelpSection(
            title: "Launcher",
            symbol: "square.grid.2x2",
            body: """
            Every tally as a clickable card — tinted with its first mark's colour and \
            showing the icon picked in Tallies. A tally with no marks of its own (say, \
            quick marks do all the work) is tinted with the fallback colour picked \
            there instead. Click to start the tally; a card whose \
            tally is currently running is dimmed until it stops (other cards keep \
            working, since moments may overlap). The dashed **＋** card creates a new \
            tally.
            """),
        HelpSection(
            title: "Log",
            symbol: "list.bullet.rectangle",
            body: """
            The week's moments, day by day. Click a row to edit in place — start and \
            end (the arrows step by the minute), marks, note — or delete it.

            A row whose mark combination matches no saved tally shows a **＋**: it \
            saves those marks as a new tally, so an ad-hoc moment you keep repeating is \
            one click from becoming a tally.
            """),
        HelpSection(
            title: "Calendar",
            symbol: "calendar",
            body: """
            The same week as a time grid, moments as coloured blocks (overlapping \
            moments share the column; moments crossing midnight draw one block per day). \
            Click a block to open it in the Log, where it expands for editing.
            """),
        HelpSection(
            title: "History",
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

            Chart colours come from a fixed palette; with *Colour marks by value* on, \
            your per-value colours win so the charts match the pills elsewhere.
            """),
        HelpSection(
            title: "Mark Review",
            symbol: "stethoscope",
            body: """
            Scans your moments (pick how far back) and lists every mark key with its \
            values and usage counts — the keys with the most distinct values first, \
            which is where typos, near-duplicates, and casing drift show up.

            Cleanups are **staged, not immediate**. Rename a key or value from its \
            pencil; drag a value onto another key to move it there; expand a value and \
            shift-click instances to drag just a subset. Staged changes collect at the \
            bottom as red→green sentences where the target spelling stays editable. \
            **Approve Changes** then rewrites the affected moments one by one, with \
            progress and cancel.

            Two boundaries to know: rewrites only touch the **scanned range** — moments \
            outside it keep their old marks (scan wider to catch them; approving again \
            after a failure or cancel safely picks up where it left off) — and \
            **running moments are never rewritten**; stop them first, then rescan.
            """),
        HelpSection(
            title: "Settings",
            symbol: "gear",
            body: """
            **Storage** is a local database on this Mac — the default needs no server \
            and no account. **Sync** optionally connects a sync server: sign in once \
            and this Mac gets a device token (revocable server-side; your password is \
            never stored). From then on every change — starting and stopping \
            moments, edits, colours, tallies, the settings below — lands locally \
            first and syncs in the background, so nothing waits on the network and \
            offline edits catch up on reconnect. If the same thing was edited on two \
            Macs, the most recent edit wins. **Import from Traggo** copies an existing \
            Traggo server's history into the local database (safe to re-run).

            **Quick-start tallies** caps how many tallies the popover lists (0 shows \
            all). **Colour marks by value** (on by default) enables the per-pair colour \
            overrides described above; turn it off to colour strictly by key. With a \
            sync server connected, both follow your account across Macs.
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
