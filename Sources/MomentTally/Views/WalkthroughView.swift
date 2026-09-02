import SwiftUI
import AppKit
import Charts
import MomentTallyCore
import MomentTallyKit

/// The interactive walkthrough of the mark model (issue #93), presented as
/// seven Next/Back pages. Every page reads and mutates the one shared
/// `WalkthroughModel`, so state carries across pages deliberately: a smell
/// activated on page 4 keeps corrupting the charts until it is healed.
///
/// - `walkthrough` — the shared dataset: the demo week, the group-by key, the
///   schema-smell selection, aggregation, and colors.
/// - `replay` — a revisit from Help (issue #192): the tally-creation page goes
///   read-only and the footer wording drops the first-run framing.
/// - `onBack` — return to the Welcome step; nil on replay (no Welcome).
/// - `onContinue` — end onboarding (finished *or* skipped); the caller closes
///   the window and, first-run only, opens the Tallies tab.
struct WalkthroughView: View {
    @Bindable var walkthrough: WalkthroughModel
    var replay = false
    var onBack: (() -> Void)?
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    /// Whether the last navigation went forward — decides the slide direction.
    @State private var forward = true

    private static let pageCount = 7

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: SpanIsLabelsPage(walkthrough: walkthrough)
                    case 1: AggregatePage(walkthrough: walkthrough)
                    case 2: LabelingSchemesPage()
                    case 3: SmellsPage(walkthrough: walkthrough)
                    case 4: LabelSetsConceptPage()
                    case 5: CreateLabelSetsPage(walkthrough: walkthrough, replay: replay)
                    default: SurfacesPage()
                    }
                }
                .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()   // sliding pages must not escape the fixed window

            progressDots
            Divider()
            // On replay the first page has nowhere to go back to, and
            // "Skip Tour"/"Continue" read wrong for a revisit.
            OnboardingFooter(back: page == 0 && onBack == nil ? nil : goBack,
                             primaryTitle: page == Self.pageCount - 1
                                 ? (replay ? "Done" : "Continue") : "Next",
                             primaryAction: goNext) {
                Button(replay ? "Close" : "Skip Tour", action: onContinue)
            }
        }
        // Healing a smell can strand the page-2 picker on a key the dataset no
        // longer has (e.g. `proj` after healing drifting keys) — fall back.
        .onChange(of: walkthrough.groupableKeys) { _, keys in
            if !keys.contains(walkthrough.groupKey) { walkthrough.groupKey = "project" }
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return forward
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }

    private func go(to target: Int) {
        forward = target > page
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { page = target }
    }

    private func goBack() {
        if page == 0 { onBack?() } else { go(to: page - 1) }
    }

    private func goNext() {
        if page == Self.pageCount - 1 { onContinue() } else { go(to: page + 1) }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.bottom, 10)
        .accessibilityLabel("Page \(page + 1) of \(Self.pageCount)")
    }
}

// MARK: - Shared page chrome

/// Common scaffold: mono step numeral (HelpView's rule style) + heading +
/// one-line subtitle, then the page's interactive hero filling the rest.
/// Top padding keeps the heading clear of the floating traffic lights.
private struct WalkthroughPage<Content: View>: View {
    let index: Int
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    // The brand script where the build bundles it; the sans
                    // it always wore otherwise. Sized up because the script's
                    // x-height runs well under title2's.
                    .font(Brand.script(24) ?? .title2.weight(.semibold))
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 12)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension View {
    /// Clickable-thing affordance for mock UI that lacks the system button
    /// look. Pass false to keep the arrow (a card that stopped being a button).
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// One-time discoverability glow (driven by the caller's state; callers
    /// never turn it on under Reduce Motion).
    func discoveryGlow(_ on: Bool) -> some View {
        shadow(color: Color.accentColor.opacity(on ? 0.9 : 0), radius: on ? 5 : 0)
    }
}

// MARK: - Page 1: a moment is its marks

private struct SpanIsLabelsPage: View {
    @Bindable var walkthrough: WalkthroughModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The mock timer: a fake base offset that keeps ticking while "running".
    @State private var baseElapsed: TimeInterval = 42 * 60 + 17
    @State private var runningSince: Date? = Date()

    // The inline editor, mirroring the popover's `timerEditor`.
    @State private var editing = false
    @State private var tagDrafts: [TagRow] = []
    @State private var noteDraft = ""

    /// Which editor field holds focus — commits ride on its changes, so
    /// Return *or* clicking away updates the pills reactively.
    private enum EditorField: Hashable {
        case key(UUID), value(UUID), note
    }
    @FocusState private var focusedField: EditorField?

    /// One-time pulse pointing at the interactive bits; never under Reduce
    /// Motion.
    @State private var pulsing = false

    private var anim: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    var body: some View {
        WalkthroughPage(index: 0, title: "A timer is nothing without its marks",
                        subtitle: "No folders, no project tree — a timer records a stretch of time plus key: value marks and notes. This one is live: try it.") {
            VStack(alignment: .leading, spacing: 14) {
                mockPopoverCard
                Text(walkthrough.mockupSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("You can always start a blank timer and mark it later, if you want.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: startPulse)
    }

    private func startPulse() {
        guard !reduceMotion, !pulsing else { return }
        withAnimation(.easeInOut(duration: 0.6).delay(0.6).repeatCount(5, autoreverses: true)) {
            pulsing = true
        }
        Task {
            try? await Task.sleep(for: .seconds(4.2))
            withAnimation(.easeOut(duration: 0.6)) { pulsing = false }
        }
    }

    /// A compact working rendition of the real popover's running row.
    private var mockPopoverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(runningSince == nil ? "Stopped" : "Running")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                elapsedText
                if walkthrough.mockupLabels.isEmpty {
                    Text("No marks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(walkthrough.mockupLabels, id: \.self) { label in
                            removablePill(label)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    editing ? cancelEditing() : beginEditing()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(HoverIconButtonStyle())
                .pointingHandCursor()
                .discoveryGlow(pulsing)
                .help("Edit marks and note")
                Button(action: toggleTimer) {
                    Image(systemName: runningSince == nil ? "play.fill" : "stop.fill")
                }
                .buttonStyle(HoverIconButtonStyle())
                .pointingHandCursor()
                .discoveryGlow(pulsing)
                .help(runningSince == nil ? "Start again" : "Stop")
            }
            if !editing, !walkthrough.mockupNote.isEmpty {
                Text(walkthrough.mockupNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            if editing {
                mockEditor
            }
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var elapsedText: some View {
        // Ticks while running; a plain frozen Text while stopped (no need to
        // keep a timeline alive for a static value).
        if let since = runningSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(baseElapsed + max(0, context.date.timeIntervalSince(since))))
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        } else {
            Text(Self.clock(baseElapsed))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func toggleTimer() {
        if let since = runningSince {
            baseElapsed += max(0, Date().timeIntervalSince(since))
            runningSince = nil
        } else {
            runningSince = Date()
        }
    }

    /// Only the ⨯ removes — the pill body is a fact, not a button.
    private func removablePill(_ label: SpanLabel) -> some View {
        let color = WalkthroughModel.color(key: label.key, value: label.value)
        return HStack(spacing: 4) {
            Text("\(label.key): \(label.value)")
            Button {
                withAnimation(anim) { walkthrough.removeMockup(label) }
                // Keep an open editor in step, or its next commit would
                // resurrect the pill.
                tagDrafts.removeAll { $0.key == label.key && $0.value == label.value }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Remove \(label.key): \(label.value)")
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color))
        .foregroundStyle(color.contrastingTextColor)
    }

    // MARK: The inline editor (mirrors MenuContentView.timerEditor)

    /// Same rows as the real editor, minus `TagColorPicker` — that writes the
    /// user's color store, which the walkthrough's demo data must not touch —
    /// so a static swatch stands in. Return in a label field, or focus moving
    /// anywhere, commits the drafts to the pills; Done just closes.
    private var mockEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($tagDrafts) { $tag in
                HStack(spacing: 6) {
                    TagColorChip(color: WalkthroughModel.color(key: tag.key,
                                                               value: tag.value))
                    TextField("key", text: $tag.key)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: LabelEditorStyle.keyFieldWidth)
                        .focused($focusedField, equals: .key(tag.id))
                        .onSubmit(commitEdits)
                    Text(":").foregroundStyle(.secondary)
                    TextField("value", text: $tag.value)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .value(tag.id))
                        .onSubmit(commitEdits)
                    Button(role: .destructive) {
                        // Read the id before removeAll — reading the `tag`
                        // binding inside the predicate re-enters the array's
                        // exclusive access and traps.
                        let id = tag.id
                        tagDrafts.removeAll { $0.id == id }
                        commitEdits()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                tagDrafts.append(TagRow())
            } label: {
                Label("Add Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            TextField("Add a note…", text: $noteDraft)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .note)
                .onSubmit(saveEdits)
            HStack {
                Spacer()
                Button("Cancel", action: cancelEditing)
                    .buttonStyle(.borderless)
                Button("Done", action: saveEdits)
            }
        }
        // "Clicking off" a field is a focus change — commit on every move,
        // so the pills above always mirror the fields.
        .onChange(of: focusedField) { _, _ in commitEdits() }
    }

    private func beginEditing() {
        let rows = walkthrough.mockupLabels.map { TagRow(key: $0.key, value: $0.value) }
        tagDrafts = rows.isEmpty ? [TagRow()] : rows
        noteDraft = walkthrough.mockupNote
        withAnimation(anim) { editing = true }
    }

    private func cancelEditing() {
        withAnimation(anim) { editing = false }
    }

    /// Push the drafts into the pills without closing the editor.
    private func commitEdits() {
        withAnimation(anim) {
            walkthrough.commitMockup(labels: tagDrafts.labels, note: noteDraft)
        }
    }

    private func saveEdits() {
        commitEdits()
        withAnimation(anim) { editing = false }
    }
}

// MARK: - Page 2: marks aggregate

private struct AggregatePage: View {
    @Bindable var walkthrough: WalkthroughModel

    var body: some View {
        WalkthroughPage(index: 1, title: "Marks group up",
                        subtitle: "This is what a typical week of marked moments looks like. See where time was spent simply by grouping these marks together.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    weekList
                    MiniChartsPane(walkthrough: walkthrough)
                        .frame(width: 270)
                }
                Text("Colors follow marks around: the same color on the marks and in the charts. Customize colors to your liking in Settings!")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var weekList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let byDay = Dictionary(grouping: walkthrough.spans, by: \.day)
                ForEach(byDay.keys.sorted(), id: \.self) { day in
                    HStack(alignment: .top, spacing: 8) {
                        Text(walkthrough.date(day: day), format: .dateTime.weekday(.abbreviated))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(byDay[day] ?? []) { span in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(formatDuration(span.seconds))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 42, alignment: .trailing)
                                    FlowLayout(spacing: 4) {
                                        ForEach(span.labels, id: \.self) { label in
                                            TagPill(key: label.key, value: label.value,
                                                    color: WalkthroughModel.color(key: label.key,
                                                                                  value: label.value))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.trailing, 6)
        }
    }
}

/// Mini donut + stacked daily bar fed by the shared model — the same pane
/// sits on pages 2 and 4 so corruptions carry over visibly. Page 2 exposes
/// the group-by picker; page 4 passes `fixedKey` to pin the grouping to the
/// key each smell damages best. Chart mutations animate because every write
/// (picker, smell selection) happens inside `withAnimation`.
private struct MiniChartsPane: View {
    @Bindable var walkthrough: WalkthroughModel
    /// When set, charts pin to this key and the picker is replaced by a
    /// caption.
    var fixedKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var key: String { fixedKey ?? walkthrough.groupKey }

    var body: some View {
        let totals = walkthrough.totals(by: key)
        let colors = walkthrough.colorMap(for: totals, key: key)
        VStack(alignment: .leading, spacing: 10) {
            if fixedKey == nil {
                Picker("Group by", selection: animatedGroupKey) {
                    ForEach(walkthrough.groupableKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .fixedSize()
            } else {
                (Text("Grouped by ").foregroundStyle(.secondary)
                    + Text(key).fontWeight(.semibold))
                    .font(.caption)
            }
            HStack {
                Spacer(minLength: 0)
                donut(totals, colors: colors)
                Spacer(minLength: 0)
            }
            legend(totals, colors: colors)
            dailyBar(colors: colors)
        }
    }

    /// Routes picker writes through `withAnimation` so both charts re-slice
    /// rather than jump.
    private var animatedGroupKey: Binding<String> {
        Binding(get: { walkthrough.groupKey },
                set: { key in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                        walkthrough.groupKey = key
                    }
                })
    }

    private func donut(_ totals: [SeriesTotal], colors: [String: Color]) -> some View {
        let missing = walkthrough.missingSeconds(for: key)
        return Chart(totals) { item in
            SectorMark(angle: .value("Time", item.seconds),
                       innerRadius: .ratio(0.62),
                       angularInset: 1.5)
                .foregroundStyle(colors[item.label] ?? .gray)
                .cornerRadius(2)
        }
        .chartLegend(.hidden)   // the compact legend below is the legend
        .frame(width: 140, height: 140)
        .overlay {
            // The centre stays empty — the slices are the story — except
            // when a smell is hiding hours: then it names the loss.
            if missing > 0 {
                VStack(spacing: 0) {
                    Text("time missing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("~\(Int((missing / 3600).rounded()))h")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
        }
    }

    private func legend(_ totals: [SeriesTotal], colors: [String: Color]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(totals) { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(colors[item.label] ?? .gray)
                        .frame(width: 6, height: 6)
                    Text(item.label)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
    }

    private func dailyBar(colors: [String: Color]) -> some View {
        Chart(walkthrough.dailyTotals(by: key)) { item in
            BarMark(x: .value("Day", item.day, unit: .day),
                    y: .value("Hours", item.seconds / 3600))
                .foregroundStyle(colors[item.label] ?? .gray)
                .cornerRadius(2)
        }
        .chartLegend(.hidden)
        // Pin to the whole demo week or sparse data would stretch its bars.
        .chartXScale(domain: walkthrough.weekInterval.start...walkthrough.weekInterval.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 96)
    }
}

// MARK: - Page 3: marking schemes

/// Static copy page between the aggregation demo and the smells: keep the
/// scheme small, put the overflow in notes — so "don't grow the scheme"
/// lands before the ways a grown scheme goes wrong.
private struct LabelingSchemesPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One entry in the rotating hero: a scheme's keys, and the caption
    /// tying its dimension count to the work it runs.
    private struct Scheme {
        let keys: [String]
        let caption: String
    }

    /// Good schemes at every dimensionality, building up — one key is
    /// enough for a bookshelf, four run a software shop.
    private static let schemes: [Scheme] = [
        Scheme(keys: ["book"],
               caption: "A simple 'book' mark can track any number of books."),
        Scheme(keys: ["project", "type"],
               caption: "Two marks can cover most general types of work."),
        Scheme(keys: ["project", "deliverable", "client", "type"],
               caption: "Four marks can cover complex workflows."),
    ]

    @State private var schemeIndex = 0

    var body: some View {
        WalkthroughPage(index: 2, title: "Marking schemes",
                        subtitle: "Don't overcomplicate it — a timer that accumulates half a dozen or more marks gets complicated fast.") {
            VStack(alignment: .leading, spacing: 14) {
                rotatingSchemes

                Text("Things will pop up that feel like they should be a mark but don't fit your scheme — write those as notes instead:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                dilemmaCard

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(.tint)
                    Text("Mark Review shows when notes develop a trend — problem: this, problem: that. If you notice that happening, it's okay to add to your scheme. Decide what works best in your workflow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Moment Tally lets you save custom marking schemes as Tallies — that's next.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The rotating hero: one scheme's key pills over its caption, fading
    /// to the next every few seconds. The cycle still runs under Reduce
    /// Motion (it is content, not decoration) — only the cross-fade goes.
    private var rotatingSchemes: some View {
        ZStack {
            let scheme = Self.schemes[schemeIndex]
            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    ForEach(scheme.keys, id: \.self) { key in
                        keyPill(key)
                    }
                }
                Text(scheme.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(schemeIndex)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                    schemeIndex = (schemeIndex + 1) % Self.schemes.count
                }
            }
        }
    }

    /// The temptation and its answer: the one-off that "feels" like a label,
    /// kept as a note so the context sticks to the span without a new key.
    private var dilemmaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“I'm editing the wedding album but went down a rabbit hole recovering the second shooter's corrupted memory card — should I mark it problem: corrupted-card?”")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            (Text("No — ").fontWeight(.semibold)
                + Text("this information is better suited for a Note. Notes stick with the moment, so the context is preserved without complicating the scheme."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("1:12:07")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    FlowLayout(spacing: 4) {
                        TagPill(key: "project", value: "wedding-shoot",
                                color: WalkthroughModel.color(key: "project",
                                                              value: "wedding-shoot"))
                        TagPill(key: "deliverable", value: "album",
                                color: WalkthroughModel.color(key: "deliverable",
                                                              value: "album"))
                    }
                    Text("Rabbit hole: recovering the corrupted memory card.")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func keyPill(_ key: String) -> some View {
        let color = WalkthroughModel.keyColor(key)
        return Text("\(key):")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .foregroundStyle(color.contrastingTextColor)
    }
}

// MARK: - Page 4: why schemes fail

private struct SmellsPage: View {
    @Bindable var walkthrough: WalkthroughModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WalkthroughPage(index: 3, title: "Why schemes fail",
                        subtitle: "Four ways a marking scheme goes wrong — Moment Tally helps you dodge all of these by defining your marks up front. Click a card to corrupt the week; click it again and the charts heal.") {
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(WalkthroughModel.SchemaSmell.allCases) { smell in
                            smellCard(smell)
                        }
                    }
                    .padding(.trailing, 6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    // Each smell pins the charts to the key that shows its
                    // damage best; healthy weeks default to project.
                    MiniChartsPane(walkthrough: walkthrough,
                                   fixedKey: walkthrough.activeSmell?.demoKey ?? "project")
                    if let smell = walkthrough.activeSmell {
                        smellDetail(smell)
                    } else {
                        Label {
                            Text("A healthy scheme: every mark lands in a slice, and both charts tell one story.")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                }
                .frame(width: 260)
            }
        }
    }

    /// The red callout beside the corrupted charts. Fused facts and drifting
    /// keys get bespoke treatments — the one-line `sideEffect` wasn't enough
    /// to make their counter-examples land for a new user.
    /// (fixedSize throughout: the column is height-constrained and a tall
    /// legend would otherwise squeeze the text to one truncated line.)
    @ViewBuilder
    private func smellDetail(_ smell: WalkthroughModel.SchemaSmell) -> some View {
        switch smell {
        case .fusedFacts:
            // Lead with the question, prove it with the fused labels, then
            // say why the query has nothing to join on.
            VStack(alignment: .leading, spacing: 6) {
                Text("“How much meeting time across all projects?”")
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 4) {
                    ForEach(walkthrough.fusedExamples, id: \.self) { label in
                        TagPill(key: label.key, value: label.value,
                                color: WalkthroughModel.color(key: label.key,
                                                              value: label.value))
                    }
                }
                Text("These meetings sit greyed in the charts — fused inside work:, where type: meeting can't match them.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .driftingKeys:
            let pct = Int((walkthrough.missingSeconds(for: "project")
                / max(walkthrough.weekTotalSeconds, 1) * 100).rounded())
            Text("You queried project: — but \(pct)% of your time was accidentally marked proj:. It rides along here greyed out as missing time; the real History tab would simply drop it.")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text(smell.sideEffect)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func smellCard(_ smell: WalkthroughModel.SchemaSmell) -> some View {
        let active = walkthrough.activeSmell == smell
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                // Radio semantics: one corruption at a time reads cleanly.
                walkthrough.activeSmell = active ? nil : smell
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(smell.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: active
                          ? "exclamationmark.triangle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(active ? AnyShapeStyle(.red)
                                                : AnyShapeStyle(.quaternary))
                }
                Text(smell.symptom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !smell.examples.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(smell.examples, id: \.label) { example in
                            HStack(spacing: 3) {
                                Image(systemName: example.good ? "checkmark" : "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(example.good
                                                     ? AnyShapeStyle(.green)
                                                     : AnyShapeStyle(.red))
                                Text(example.label)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                (Text("Fix  ").foregroundStyle(.tint).bold()
                    + Text(smell.fix))
                    .font(.caption)
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .padding(.leading, 5)
            .contentShape(Rectangle())
            .background(.quinary)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.red.opacity(active ? 0.9 : 0.3))
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.red.opacity(active ? 0.5 : 0)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: - Page 5: tallies, the anatomy

/// The Tallies concept page: one mock quick-start row wearing all three
/// moving parts — baked-in marks, a valueless mark, quick marks — each
/// tagged with a numbered callout the legend beside it explains. Interactive
/// like the real popover row: chips apply and swap, the row body starts
/// plain, and every start lands focus in the valueless label's field below,
/// the same copy-a-number-click-paste flow the real editor runs (#149).
/// All mock — this page writes nothing; creation is the next page's job.
private struct LabelSetsConceptPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Quick: Hashable {
        let key: String
        let value: String
    }

    private static let baked = SpanLabel(key: "project", value: "rebrand")
    /// The valueless label: no value baked into the set, so every start
    /// prompts for one.
    private static let valuelessKey = "deliverable"
    private static let quicks = [Quick(key: "type", value: "design"),
                                 Quick(key: "type", value: "revisions"),
                                 Quick(key: "type", value: "invoicing")]

    @State private var applied: Quick?
    @State private var valueDraft = ""
    @FocusState private var valueFocused: Bool

    private var anim: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    var body: some View {
        WalkthroughPage(index: 4, title: "Tallies",
                        subtitle: "Save your marking scheme as named tallies that start with one click. This mock tally wears all three moving parts — it's live, click around.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 24) {
                    mockRow
                        .frame(width: 280)
                    legend
                }
                preview
                Text("A tally can even be nothing but quick marks — a tidy home for hobbies: book:, game:, show:. Up next: create your own.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// A quick-start row like the popover's, chips permanently revealed (the
    /// real row shows them on hover). As in the popover, the row itself is
    /// the click target for "just the set" — anywhere that isn't a chip.
    private var mockRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick start")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                start(applying: nil)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Client Rebrand")
                        .font(.callout)
                    .padding(.top, 4)
                    FlowLayout(spacing: 4) {
                        badge(1).padding(.trailing, 2)
                        TagPill(key: Self.baked.key, value: Self.baked.value,
                                color: WalkthroughModel.color(key: Self.baked.key,
                                                              value: Self.baked.value))
                        TagPill(key: Self.valuelessKey, value: "",
                                color: WalkthroughModel.keyColor(Self.valuelessKey))
                        badge(2).padding(.leading, 2)
                    }
                    .padding(.top, 4)
                    FlowLayout(spacing: 4) {
                        badge(3).padding(.trailing, 2)
                        ForEach(Self.quicks, id: \.self) { quick in
                            chip(quick)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(10)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Start with the tally's marks")
        }
    }

    /// Chips apply, they never toggle off — like the popover, where a chip
    /// always means "start with this"; the row body is the way back to the
    /// set's plain labels. So switching types is endlessly repeatable.
    private func chip(_ quick: Quick) -> some View {
        Button {
            start(applying: quick)
        } label: {
            // The default chip spelling — the walkthrough's mock predates
            // any preference tweaking, so it shows the stock look (#186).
            Text("+\(quick.value)")
        }
        .buttonStyle(QuickLabelChipStyle(
            color: WalkthroughModel.color(key: quick.key, value: quick.value),
            filled: applied == quick))
        .pointingHandCursor()
        .help("Start with \(quick.key): \(quick.value)")
    }

    /// Every click is a fresh mock start: apply (or clear) the quick label,
    /// blank the valueless field, and focus it — the #149 flow in miniature.
    private func start(applying quick: Quick?) {
        withAnimation(anim) { applied = quick }
        valueDraft = ""
        valueFocused = true
    }

    private func badge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.primary)
            .frame(width: 15, height: 15)
            .background(Circle().strokeBorder(Color.accentColor, lineWidth: 1))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            legendRow(1, "Baked-in marks",
                      "The tally's main marks. Clicking the row starts a timer with just the tally's own marks.")
            legendRow(2, "A valueless mark",
                      "Sometimes you don't know what the mark should be until you're ready to start a timer. Leave the value field blank, then just type or paste the value when starting a timer")
            legendRow(3, "Quick marks",
                      "An optional extra mark as you start. Useful for dividing up time into sub categories")
        }
    }

    private func legendRow(_ number: Int, _ title: String,
                           _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            badge(number)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The span a click would start: the baked label, the applied quick
    /// label, and the valueless label as a live field — typing into it is
    /// the page's proof of the prompt-per-start workflow.
    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("One click starts:")
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                TagPill(key: Self.baked.key, value: Self.baked.value,
                        color: WalkthroughModel.color(key: Self.baked.key,
                                                      value: Self.baked.value))
                valuelessField
                if let applied {
                    TagPill(key: applied.key, value: applied.value,
                            color: WalkthroughModel.color(key: applied.key,
                                                          value: applied.value))
                }
            }
        }
        .padding(.top, 4)
    }

    /// The valueless label at start time: a pill-shaped field awaiting its
    /// value, focused by every mock start.
    private var valuelessField: some View {
        HStack(spacing: 3) {
            Text("\(Self.valuelessKey):")
            TextField("logo-v2", text: $valueDraft)
                .textFieldStyle(.plain)
                .focused($valueFocused)
                .frame(width: 64)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(
            WalkthroughModel.keyColor(Self.valuelessKey)))
    }
}

// MARK: - Page 6: create your first tallies

/// One way people run Moment Tally — a card on the create page, whose editor
/// also includes the persona's suggested quick labels by default.
private struct WalkthroughPersona: Identifiable {
    let name: String
    let symbol: String
    /// The primary keys, with example values — hints, never prefilled.
    /// A nil example seeds a *valueless* label, the concept page's
    /// prompt-per-start workflow. (The work *type* is deliberately
    /// absent: that's a quick label's job, not a set's — the editor
    /// suggests those below the rows.)
    let rows: [(key: String, example: String?)]
    /// The example set name woven into the editor's prompt — Tab in the
    /// empty name field accepts it verbatim.
    let nameExample: String
    /// The editor's suggested quick labels, seeded as editable rows —
    /// kinds of work under the conventional key `type:` for the working
    /// personas; Leisure's instead carry one key per hobby, the
    /// quick-labels-only pattern the concept page teased.
    let quickLabels: [(key: String, value: String)]
    var id: String { name }

    /// The editor's name-field prompt: a directive nudge toward a readable,
    /// chart-legend-friendly set name, phrased around the example labels.
    var nameHint: String { "Pick something readable like \(nameExample)" }

    /// The conventional quick-label key — adopted outright on page 6.
    static let quickKey = "type"

    /// The App Store submission's four: common cases over coverage, and —
    /// per the #27 breadth pass — none of them programmer-centric (the old
    /// Programming card's `repo:`/`issue:` examples read as insider
    /// vocabulary to the wider audience). Freelance deliberately mirrors
    /// the concept page's mock set — same valueless `deliverable:`, same
    /// quick-label trio — so the card reads as "that thing you just
    /// clicked around, for real". Leisure is the quick-labels-only set
    /// the concept page's caption promised.
    static let all: [WalkthroughPersona] = [
        WalkthroughPersona(name: "Freelance", symbol: "briefcase",
                           rows: [("client", "acme"),
                                  ("deliverable", nil)],
                           nameExample: "Client Rebrand",
                           quickLabels: [("type", "design"),
                                         ("type", "revisions"),
                                         ("type", "invoicing")]),
        WalkthroughPersona(name: "Studying", symbol: "graduationcap",
                           rows: [("course", "linear-algebra"),
                                  ("topic", nil)],
                           nameExample: "Linear Algebra",
                           quickLabels: [("type", "lecture"),
                                         ("type", "group-session"),
                                         ("type", "homework")]),
        WalkthroughPersona(name: "Creative Work", symbol: "paintbrush",
                           rows: [("project", "wedding-shoot")],
                           nameExample: "Wedding Shoot",
                           quickLabels: [("type", "photoshoot"),
                                         ("type", "editing")]),
        WalkthroughPersona(name: "Leisure", symbol: "sofa",
                           rows: [],
                           nameExample: "Off the Clock",
                           quickLabels: [("book", "the-wayfinder"),
                                         ("game", "baldurs-gate"),
                                         ("show", "ted-lasso")]),
    ]

    static func named(_ id: String) -> WalkthroughPersona? {
        all.first { $0.id == id }
    }
}

/// The four personas of the catalogue above, each openable into a small
/// editor that creates a *real* label set — quick labels included — the
/// walkthrough's one page that writes into the user's data, because that's
/// its whole point. It assumes everything the concept page just taught, so
/// the copy stays action-dense: no re-explaining what a set or a quick
/// label is.
///
/// On `replay` the page is a look-don't-touch catalogue: the editor never
/// opens (re-adding a persona to a configured account would duplicate
/// tallies and overwrite value colors — the dedupe is name-based only),
/// and the footer points at Settings → Tallies instead.
private struct CreateLabelSetsPage: View {
    @Environment(AppModel.self) private var model
    @Bindable var walkthrough: WalkthroughModel
    var replay = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Persona = WalkthroughPersona

    /// The grid's rows, two cards per row.
    private static let personaPairs: [[Persona]] =
        stride(from: 0, to: Persona.all.count, by: 2).map {
            Array(Persona.all[$0..<min($0 + 2, Persona.all.count)])
        }

    /// One editable label row in the persona editor — the popover editor's
    /// key/value rows plus a color swatch, with the persona's example as
    /// placeholder on seeded rows.
    private struct DraftRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var color: Color
        var example: String?

        var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
        var trimmedValue: String { value.trimmingCharacters(in: .whitespaces) }
        /// Nothing typed at all — silently dropped on add, like an unused
        /// "Add Mark" click.
        var isBlank: Bool { trimmedKey.isEmpty && trimmedValue.isEmpty }
        /// A value with no key can't become a label — the one refusal left.
        var missingKey: Bool { trimmedKey.isEmpty && !trimmedValue.isEmpty }
        /// A key with no value is legal: the set prompts for the value on
        /// every start (the concept page's deliverable: workflow) — worth a
        /// heads-up in the editor, not a refusal.
        var valueless: Bool { !trimmedKey.isEmpty && trimmedValue.isEmpty }
    }

    @State private var editing: Persona?
    /// The quick-label drafts, an editable list like the Tallies tab's —
    /// seeded with the persona's three suggestions (or, in edit mode, the
    /// set's real quick labels).
    @State private var quickDrafts: [DraftRow] = []
    /// Hover-expanded card, popover-style: the card grows to reveal its
    /// quick labels after the pointer rests briefly (`cardHovered`).
    @State private var hoveredID: String?
    @State private var pendingHoverID: String?
    @State private var hoverTask: Task<Void, Never>?
    /// Tallest card in the grid — every card takes it as a floor, so a card
    /// whose pills fit one line doesn't run shorter than its neighbours; its
    /// content centres in the extra room.
    @State private var cardHeight: CGFloat = 0
    /// The floor is measured once, before any hover: an expanded card
    /// stretches its row-mate, whose (collapsed!) reported height would
    /// otherwise ratchet the floor up for good. The window never resizes,
    /// so the initial measurement stays right.
    @State private var cardHeightLocked = false
    @State private var draftName = ""
    @State private var draftRows: [DraftRow] = []
    /// Rows flagged by a failed add — their empty fields stay outlined red
    /// until filled. No "required" copy anywhere, per the review.
    @State private var invalidRows: Set<UUID> = []
    /// Failed-add counter; each bump drives one shake of the add button.
    @State private var shakes = 0
    /// The draft's fingerprint as `open(_:)` seeded it — `autosave()`
    /// compares against it to tell an edited draft from mere browsing.
    @State private var openedSignature: [String] = []

    /// The real set behind an already-added persona, if it still exists —
    /// from the shared model, so it survives paging away and back. Added
    /// cards display this set's actual labels (not the persona examples),
    /// and reopening one edits it in place.
    private func createdSet(for persona: Persona) -> TagSet? {
        guard let created = walkthrough.createdSets.first(where: {
            $0.personaID == persona.id
        }) else { return nil }
        return model.tagSets.first { $0.id == created.setID }
    }

    var body: some View {
        WalkthroughPage(index: 5, title: replay ? "Starter Tallies" : "Create your first Tallies",
                        subtitle: replay
                            ? "Four ways people run Moment Tally. On a first run, this page turns them into real one-click tallies."
                            : "Four ways people run Moment Tally. Open one, make it yours — it becomes a real one-click tally, quick marks and all.") {
            Group {
                if let persona = editing {
                    // The editor (labels + quick labels) can outgrow the
                    // fixed window — scroll rather than clip.
                    ScrollView {
                        editor(for: persona)
                            .frame(maxWidth: 460)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    // A ScrollView so a hover-expanded card pushes the rows
                    // below it down (the popover's expand mechanic) instead
                    // of overflowing the fixed page.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            // Deliberately not a LazyVGrid: lazy cells
                            // materialise mid page-slide, so the cards
                            // visibly popped in while the text was still
                            // moving.
                            ForEach(Array(Self.personaPairs.enumerated()),
                                    id: \.offset) { _, pair in
                                HStack(alignment: .top, spacing: 10) {
                                    ForEach(pair) { persona in
                                        card(for: persona)
                                            .frame(maxWidth: .infinity)
                                    }
                                    if pair.count == 1 {
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                                // Cards whose pills fit one line would
                                // otherwise run shorter than their neighbour:
                                // the row takes the taller card's height, the
                                // shorter one stretches to match (content
                                // centres, below).
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            if replay {
                                // The immutable-replay pointer: your tallies
                                // already exist — edit them where they live.
                                HStack(spacing: 4) {
                                    Text("Your tallies stay as they are on a replay —")
                                        .foregroundStyle(.tertiary)
                                    Button("manage them in Settings → Tallies") {
                                        SettingsWindowManager.shared.show(model: model,
                                                                          tab: .tagSets)
                                    }
                                    .buttonStyle(.link)
                                }
                                .font(.caption)
                            } else {
                                Text("You can add as many Tallies as you'd like in Settings after onboarding.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: editing?.id)
            // Leaving the page — Next, Back, Skip Tour, or the window
            // closing — commits an edited draft instead of dropping it.
            .onDisappear(perform: autosave)
        }
    }

    private func card(for persona: Persona) -> some View {
        let set = createdSet(for: persona)
        // A quick-labels-only card (Leisure) has no pills — its chips are
        // its identity, so they stay visible instead of waiting for hover.
        let chipsAlwaysVisible = set?.tags.isEmpty ?? persona.rows.isEmpty
        let expanded = hoveredID == persona.id || chipsAlwaysVisible
        return Button {
            guard !replay else { return }   // look, don't touch (see above)
            open(persona)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: persona.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(persona.name).font(.body.weight(.medium))
                    // Fixed gap, top-aligned: a one-line chip row lines up
                    // with the *first* chip row of a two-line neighbour, and
                    // the card's extra height simply trails below.
                    FlowLayout(spacing: 4) {
                        if let set {
                            // The user's own labels in their palette — an
                            // added card mirrors what they created, not the
                            // example it started from.
                            ForEach(set.tags) { row in
                                TagPill(key: row.key, value: row.value,
                                        color: model.tagColor(for: row.key,
                                                              value: row.value.isEmpty
                                                                  ? nil : row.value))
                            }
                        } else {
                            // A nil example is a valueless label — a bare
                            // `key:` pill in the key's color, like the
                            // concept page's deliverable:.
                            ForEach(persona.rows, id: \.key) { row in
                                TagPill(key: row.key, value: row.example ?? "",
                                        color: WalkthroughModel.color(key: row.key,
                                                                      value: row.example ?? ""))
                            }
                        }
                    }
                    // The popover-style hover reveal: rest on a card and it
                    // grows to show its quick labels.
                    if expanded {
                        FlowLayout(spacing: 4) {
                            if let set {
                                ForEach(model.quickLabels(for: set)) { row in
                                    quickChip(row.value.isEmpty ? row.key : row.value,
                                              color: model.tagColor(for: row.key,
                                                                    value: row.value.isEmpty
                                                                        ? nil : row.value))
                                }
                            } else {
                                ForEach(Array(persona.quickLabels.enumerated()),
                                        id: \.offset) { _, quick in
                                    quickChip(quick.value,
                                              color: WalkthroughModel.color(key: quick.key,
                                                                            value: quick.value))
                                }
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                Spacer(minLength: 0)
                // No add affordance on replay — the cards are exhibits.
                if !replay {
                    Image(systemName: set != nil ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(set != nil ? AnyShapeStyle(.green)
                                                    : AnyShapeStyle(.quaternary))
                }
            }
            .padding(10)
            // Fill whatever height the row settled on — and at least the
            // grid's tallest card.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(minHeight: cardHeight > 0 ? cardHeight : nil)
            .contentShape(Rectangle())
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(!replay)   // hover-expand stays; the click cue goes
        .onHover { cardHovered(persona, inside: $0) }
        .overlay {
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self,
                                       value: proxy.size.height)
            }
        }
        .onPreferenceChange(CardHeightKey.self) {
            guard !cardHeightLocked else { return }
            cardHeight = max(cardHeight, $0)
        }
    }

    /// A non-interactive rendition of the popover's quick-label chip — the
    /// hover reveal shows what the set offers; clicking anywhere on the card
    /// still opens the editor.
    private func quickChip(_ text: String, color: Color) -> some View {
        Text("+\(text)")
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color))
    }

    /// Hover intent for a persona card, mirroring the popover's quick-start
    /// rows: expansion waits until the pointer has rested briefly, so a
    /// pass across the grid never reflows it; collapse is immediate (but
    /// animated) on exit.
    private func cardHovered(_ persona: Persona, inside: Bool) {
        if inside {
            cardHeightLocked = true   // see `cardHeightLocked`
            guard hoveredID != persona.id, pendingHoverID != persona.id else { return }
            hoverTask?.cancel()
            pendingHoverID = persona.id
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                pendingHoverID = nil
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    hoveredID = persona.id
                }
            }
        } else {
            if pendingHoverID == persona.id {
                pendingHoverID = nil
                hoverTask?.cancel()
            }
            if hoveredID == persona.id {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    hoveredID = nil
                }
            }
        }
    }

    private func open(_ persona: Persona) {
        hoverTask?.cancel()
        pendingHoverID = nil
        hoveredID = nil
        if let set = createdSet(for: persona) {
            // Edit mode: the drafts mirror the set the user already made,
            // in their own palette — Save replaces it wholesale.
            draftName = set.name
            draftRows = set.tags.map {
                DraftRow(key: $0.key, value: $0.value,
                         color: model.tagColor(for: $0.key,
                                               value: $0.value.isEmpty ? nil : $0.value))
            }
            quickDrafts = model.quickLabels(for: set).map {
                DraftRow(key: $0.key, value: $0.value,
                         color: model.tagColor(for: $0.key,
                                               value: $0.value.isEmpty ? nil : $0.value))
            }
        } else {
            // The name starts blank on purpose: the prompt is a directive
            // hint ("Pick something readable like …"), and Add stays
            // disabled until the user names the set themselves.
            draftName = ""
            // Swatches start on the walkthrough's color for the example, so
            // the editor matches the card the user just clicked; quick-label
            // seeds prefer a color the user's palette already has.
            draftRows = persona.rows.map {
                DraftRow(key: $0.key, value: "",
                         color: WalkthroughModel.color(key: $0.key, value: $0.example ?? ""),
                         example: $0.example)
            }
            quickDrafts = persona.quickLabels.map { quick in
                DraftRow(key: quick.key, value: quick.value,
                         color: model.valueColor(key: quick.key, value: quick.value)
                             ?? WalkthroughModel.color(key: quick.key, value: quick.value))
            }
        }
        invalidRows = []
        openedSignature = draftSignature()
        editing = persona
    }

    /// The persona editor: the popover's editable key/value rows (add,
    /// remove, retype — the seeded keys are suggestions, not law) with a
    /// color swatch per row.
    private func editor(for persona: Persona) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: persona.symbol)
                    .foregroundStyle(.tint)
                TextField("Tally name", text: $draftName,
                          prompt: Text(persona.nameHint))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                    // Tab completes the prompt's example while the field is
                    // empty; once anything is typed it tabs on as usual.
                    .onKeyPress(.tab) {
                        guard draftName.trimmingCharacters(in: .whitespaces).isEmpty
                        else { return .ignored }
                        draftName = persona.nameExample
                        return .handled
                    }
            }
            ForEach($draftRows) { $row in
                editorRow($row, removeFrom: $draftRows)
            }
            Button {
                draftRows.append(DraftRow(key: "", value: "",
                                          color: WalkthroughModel.keyColor("")))
            } label: {
                Label("Add Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            if draftRows.contains(where: { $0.example != nil }) {
                Text("The grey values are examples — type your own, or press Tab to keep one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if draftRows.contains(where: \.valueless) {
                Label("Blank mark values are fine — the tally will prompt for them when starting a timer.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            quickLabelsSection
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button(createdSet(for: persona) != nil ? "Save tally"
                                                       : "Add tally") {
                    add(persona)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(anyFlagged ? .red : nil)
                    .modifier(Shake(animatableData: CGFloat(shakes)))
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One key/value editor row — swatch, fields, remove — shared by the
    /// label list and the quick-label list, like the Tallies tab's twin
    /// lists. A persona example (when present) rides as placeholder with
    /// Tab completion.
    private func editorRow(_ row: Binding<DraftRow>,
                           removeFrom list: Binding<[DraftRow]>) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: row.color, supportsOpacity: false)
                .labelsHidden()
            TextField("key", text: row.key)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(width: LabelEditorStyle.keyFieldWidth)
                .overlay(invalidOutline(flagged(row.wrappedValue)
                    && row.wrappedValue.trimmedKey.isEmpty))
            Text(":").foregroundStyle(.secondary)
            TextField("value", text: row.value,
                      prompt: row.wrappedValue.example.map { Text($0) })
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onKeyPress(.tab) {
                    guard row.wrappedValue.trimmedValue.isEmpty,
                          let example = row.wrappedValue.example
                    else { return .ignored }
                    row.wrappedValue.value = example
                    return .handled
                }
            Button(role: .destructive) {
                // Read the id before removeAll — reading the binding inside
                // the predicate re-enters the array's exclusive access and
                // traps.
                let id = row.wrappedValue.id
                list.wrappedValue.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    /// The quick-label list, editable exactly like the labels above (and
    /// like the Tallies tab's own quick-label list) — seeded with the
    /// persona's suggestions, all free to retype, remove, or extend.
    private var quickLabelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick marks")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($quickDrafts) { $row in
                editorRow($row, removeFrom: $quickDrafts)
            }
            Button {
                quickDrafts.append(DraftRow(key: Persona.quickKey, value: "",
                                            color: WalkthroughModel.keyColor(Persona.quickKey)))
            } label: {
                Label("Add Quick Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Text("Offered on the tally's row as one-click swap-ins — a shared key means they swap with each other.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// A field flagged by a failed add keeps its outline only while still
    /// empty — typing clears it, without any bookkeeping.
    private func flagged(_ row: DraftRow) -> Bool {
        invalidRows.contains(row.id)
    }

    private var anyFlagged: Bool {
        draftRows.contains { flagged($0) && $0.trimmedKey.isEmpty }
    }

    private func invalidOutline(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(.red, lineWidth: 1)
            .opacity(on ? 1 : 0)
    }

    /// Create — or, for an already-added persona, update — the real set.
    /// Refusals: a value with no key (in either list), or an entirely empty
    /// draft (no labels *and* no quick labels). A blank *value* is legal —
    /// the set prompts for it per start (the caption above says so), and
    /// quick-labels-only sets are a real pattern. The refusal is shown, not
    /// written: the offending key fields outline red and the add button
    /// shakes. Chosen colors go through the model's per-value color store.
    private func add(_ persona: Persona) {
        let rows = draftRows.filter { !$0.isBlank }
        let quickRows = quickDrafts.filter { !$0.isBlank }
        let refused = (rows + quickRows).filter(\.missingKey)
        guard refused.isEmpty, !(rows.isEmpty && quickRows.isEmpty) else {
            invalidRows.formUnion(refused.map(\.id))
            if reduceMotion {
                shakes += 1   // unanimated: the red tint still lands
            } else {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
            return
        }
        save(persona, name: draftName.trimmingCharacters(in: .whitespaces),
             rows: rows, quickRows: quickRows)
    }

    /// Click-away commit (issue #258): the save button can sit below the
    /// form's fold, so it's natural to leave the page — Next, Back, Skip
    /// Tour — with the draft uncommitted, and losing it then reads as a
    /// bug. Best effort, no refusal theater: keyless rows drop, and a
    /// blank name falls back to the persona's example (the user lands in
    /// Settings → Tallies after the tour, where renaming is one click).
    /// An untouched draft is browsing, not intent — that one just closes.
    private func autosave() {
        guard let persona = editing, draftSignature() != openedSignature else { return }
        let rows = draftRows.filter { !$0.isBlank && !$0.missingKey }
        let quickRows = quickDrafts.filter { !$0.isBlank && !$0.missingKey }
        guard !(rows.isEmpty && quickRows.isEmpty) else { return }
        var name = draftName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            name = createdSet(for: persona)?.name ?? persona.nameExample
        }
        save(persona, name: name, rows: rows, quickRows: quickRows)
    }

    /// What `autosave()` diffs: everything the user can edit — name, both
    /// row lists' keys/values, and the swatches.
    private func draftSignature() -> [String] {
        [draftName] + (draftRows + quickDrafts).map { "\($0.key)|\($0.value)|\($0.color)" }
    }

    /// The shared commit tail behind `add` and `autosave` — rows are
    /// already filtered, the name already resolved.
    private func save(_ persona: Persona, name: String,
                      rows: [DraftRow], quickRows: [DraftRow]) {
        let tags = rows.map { TagRow(key: $0.trimmedKey, value: $0.trimmedValue) }
        let quickTags = quickRows.map { TagRow(key: $0.trimmedKey, value: $0.trimmedValue) }
        // Chosen colors — a valueless row has no pair to color; the value
        // arrives at start time. (Edit-mode swatches were seeded from the
        // palette, so an untouched swatch writes back its own color.)
        for row in rows + quickRows where !row.trimmedValue.isEmpty {
            model.setValueColor(key: row.trimmedKey, value: row.trimmedValue,
                                color: row.color)
        }
        let set: TagSet
        if let existing = createdSet(for: persona) {
            // Edit mode: the drafts *are* the set now — name, labels, and
            // quick labels replaced wholesale.
            set = existing
            if let index = model.tagSets.firstIndex(where: { $0.id == existing.id }) {
                model.tagSets[index].name = name
                model.tagSets[index].tags = tags
            }
            model.quickLabels[set.id.uuidString] = quickTags
        } else if let existing = model.tagSets.first(where: {
            $0.name.lowercased() == name.lowercased()
        }) {
            // A pre-existing set of the same name — counts as added; merge
            // in the quick labels without disturbing what it already has.
            set = existing
            let present = model.quickLabels(for: set)
            model.quickLabels[set.id.uuidString, default: []].append(
                contentsOf: quickTags.filter { tag in
                    !present.contains {
                        normalizeKey($0.key) == normalizeKey(tag.key)
                            && $0.value == tag.value
                    }
                })
        } else {
            set = TagSet(name: name, tags: tags, symbolName: persona.symbol)
            model.tagSets.append(set)
            model.quickLabels[set.id.uuidString] = quickTags
        }
        if !walkthrough.createdSets.contains(where: { $0.setID == set.id }) {
            walkthrough.createdSets.append(
                WalkthroughModel.CreatedSet(setID: set.id, personaID: persona.id))
        }
        editing = nil
    }
}

/// The tallest persona card's height (see `LabelSetsPage.cardHeight`).
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Horizontal shake for a refused action — driven by an incrementing
/// counter; each whole step sweeps three cycles and lands back at rest.
private struct Shake: GeometryEffect {
    var travel: CGFloat = 5
    var cycles: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * cycles * 2), y: 0))
    }
}

// MARK: - Page 7: where things live

private struct SurfacesPage: View {
    private struct Surface: Identifiable {
        let symbol: String
        let name: String
        let blurb: String
        var id: String { name }
    }

    // Blurbs mirror the website/readme feature copy.
    private static let surfaces: [Surface] = [
        Surface(symbol: "timer", name: "Menu-bar popover",
                blurb: "Start and stop timers, add notes or change marks on the fly."),
        Surface(symbol: "square.grid.2x2", name: "Launcher",
                blurb: "Saved tallies as one-click cards — icons and colors for the way you actually organize work. Tallies that are already running light up."),
        Surface(symbol: TagSet.markSymbol, name: "Tallies",
                blurb: "Name and edit the tallies behind one-click timers. Set up quick marks to fit your workflow."),
        Surface(symbol: "list.bullet.rectangle", name: "Log",
                blurb: "Review and freely edit moments after-the-fact: because real work overlaps, gets interrupted, and needs correcting."),
        Surface(symbol: "calendar", name: "Calendar",
                blurb: "Your week laid out hour by hour. Overlapping timers share columns, so multi-tasking is visible instead of hidden."),
        Surface(symbol: "chart.pie", name: "History",
                blurb: "Visualize your moments with group-by based aggregations."),
        Surface(symbol: "stethoscope", name: "Mark Review",
                blurb: "Merge drifted keys and stray values. With Moment Tally it's easy to catch these outliers and correct them before they impact downstream."),
        Surface(symbol: "gear", name: "Settings",
                blurb: "Sync, colors, and everything else."),
    ]

    var body: some View {
        WalkthroughPage(index: 6, title: "Where things live",
                        subtitle: "Everything you just did in miniature has a real surface in the app.") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Self.surfaces) { surface in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            // The brand mark under its reserved name, an SF
                            // Symbol otherwise — TagSetIcon's convention.
                            if surface.symbol == TagSet.markSymbol {
                                TallyMarkIcon(size: 24, inset: Brand.symbolInset).padding(.bottom, -8)
                            } else {
                                Image(systemName: surface.symbol)
                            }
                        }
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                        Text(surface.name)
                            .font(.callout.weight(.semibold))
                            .frame(width: 130, alignment: .leading)
                        Text(surface.blurb)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Link(destination: URL(string: "https://moment-tally.com/docs/marks")!) {
                    Label("Read the full marking guide", systemImage: "book")
                }
                .font(.callout)
                .padding(.top, 6)
                Text("Hit Continue to finish — you'll land in the Tallies tab, next to whatever you just created.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
