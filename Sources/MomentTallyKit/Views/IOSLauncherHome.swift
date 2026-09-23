#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The launcher surface, container-agnostic (#126): running timers, the
/// blank-timer row, and the quick-start card grid, re-columned to whatever
/// width it's given. The iPhone home wraps it in a NavigationStack with a
/// toolbar; the iPad split root embeds it as the leading column with
/// section buttons below. Owns the scroll, the column math, the shared
/// edit-session sheet, and pull-to-refresh.
struct LauncherSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    /// The card open across its row (#255) — grid state, since the row
    /// layout re-flows the other cards around it.
    @State private var expandedID: TagSet.ID?
    /// The running span whose editor this surface presented as a sheet.
    /// The sheet shows only for sessions opened *here* (a running row, the
    /// blank timer): the Log's expanded row claims the same shared session,
    /// and a value-less start (#255) hands off to that editor on purpose —
    /// a sheet popping over it would defeat the hand-off.
    @State private var sheetSpanID: TimeSpan.ID?

    private static let minCardWidth: CGFloat = 150
    private static let spacing: CGFloat = 12

    /// Non-nil embeds the surface as one section of a scroll an ancestor
    /// owns (#280, the portrait arrangement): no ScrollView of its own,
    /// natural height, columns from the given width — a GeometryReader
    /// has no height to offer inside someone else's scroll. Nil is the
    /// standalone surface that measures and scrolls itself.
    var embeddedWidth: CGFloat? = nil

    var body: some View {
        Group {
            if let width = embeddedWidth {
                content(width: width)
            } else {
                GeometryReader { geo in
                    ScrollView {
                        content(width: geo.size.width)
                    }
                }
                .refreshable { await model.refresh() }
            }
        }
        // The one shared edit session, as a sheet: tap a running row to
        // open it; dismissing by swipe commits, like the popover closing
        // (#70's "drafts must survive teardown" lesson — commits go
        // through the model's one funnel either way).
        .sheet(isPresented: Binding(
            get: { sheetSpanID != nil && model.editSession?.spanID == sheetSpanID },
            set: { shown in
                if !shown {
                    sheetSpanID = nil
                    if model.editSession != nil {
                        Task { await model.finishEditing() }
                    }
                }
            }
        )) {
            IOSSpanEditorSheet()
                .presentationDetents([.medium, .large])
        }
        .task { await model.refresh() }
    }

    private func content(width: CGFloat) -> some View {
        let content = width - Self.spacing * 2
        let columns = max(1, Int((content + Self.spacing)
                                 / (Self.minCardWidth + Self.spacing)))
        return VStack(alignment: .leading, spacing: 20) {
            runningSection
            quickStartSection(columns: columns)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(Self.spacing)
        // A tap on the surface outside any card collapses the open one
        // without starting (#255); cards' own buttons win over this.
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandedID != nil else { return }
            withAnimation(.snappy) { expandedID = nil }
        }
    }

    /// Every start from a card or its chips (#255): collapse, start, and —
    /// when the labels still carry a value-less one (`deliverable:`) — hand
    /// the new span to the Log's row editor with that value field focused,
    /// the #162 fill-in-the-value-per-start workflow. `requestLog` claims
    /// the session synchronously so the Log renders its expanded row in
    /// the same pass as the section switch (#130).
    private func start(_ labels: [SpanLabel]) async {
        withAnimation(.snappy) { expandedID = nil }
        guard let created = await model.start(tags: labels) else { return }
        if labels.contains(where: { $0.value.isEmpty }) {
            model.wantsValueFocusOnEditorAppear = true
            model.history.requestLog(editing: created)
            openAppSection(.log)
        }
    }

    // MARK: Running

    @ViewBuilder
    private var runningSection: some View {
        if !model.activeTimers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Running")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(model.activeTimers) { timer in
                    runningRow(timer)
                }
            }
        }

        // Ad-hoc start with no marks — capture time first, classify in the
        // editor while the clock runs. The created span opens straight into
        // the editor, same as the Mac popover's blank-timer row.
        Button {
            Task {
                if let created = await model.start(tags: []) {
                    sheetSpanID = created.id
                    await model.beginEditing(created)
                }
            }
        } label: {
            Label("Start blank timer", systemImage: "circle.dashed")
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    /// One running timespan: elapsed + marks, tap anywhere to edit, with an
    /// always-visible stop button — the popover folds stop/edit into
    /// hover-revealed icons; touch gets standing controls (#124).
    private func runningRow(_ timer: TimeSpan) -> some View {
        HStack(spacing: 12) {
            Button {
                sheetSpanID = timer.id
                Task { await model.beginEditing(timer) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.elapsedString(since: timer.start))
                        .font(.title3.monospacedDigit())
                    if timer.labels.isEmpty {
                        Text("No marks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(timer.labels, id: \.self) { tag in
                                TagPill(key: tag.key, value: tag.value,
                                        color: model.tagColor(for: tag.key,
                                                              value: tag.value))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.stop(id: timer.id) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .disabled(model.isBusy)
            .accessibilityLabel("Stop")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.fill.tertiary))
    }

    // MARK: Quick start

    private func quickStartSection(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.tagSets.isEmpty {
                ContentUnavailableView {
                    Label("No tallies yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("A tally is a one-tap timer for something you do often.")
                } actions: {
                    Button("Create a tally") {
                        model.newTagSet()
                        openAppSection(.tagSets)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // The expanded card opens in place, two slots wide, and the
                // rest re-flow (#255); one Layout over one ForEach keeps
                // every card's identity through the reshuffle, so the
                // frames animate.
                let sets = model.tagSets
                LauncherRowLayout(columns: columns, spacing: Self.spacing,
                                  expandedIndex: sets.firstIndex { $0.id == expandedID }) {
                    ForEach(sets) { set in
                        TagSetCard(set: set, expansion: CardExpansion(
                            isExpanded: expandedID == set.id,
                            expand: {
                                withAnimation(.snappy) { expandedID = set.id }
                            },
                            collapse: {
                                withAnimation(.snappy) { expandedID = nil }
                            },
                            start: { await start($0) }))
                    }
                }
            }
        }
    }
}

/// The touch launcher's card grid (#255): `columns` equal-width slots per
/// row, except that the subview at `expandedIndex` opens *in place* to two
/// slots wide (the whole row on a two-column phone) at its own natural
/// height. It stays in the row it was in and opens out from under the
/// thumb: a card in the left half grows rightward, one in the right half
/// grows leftward over its left neighbour, which is displaced and
/// re-flows after it; the cards after it re-flow around the wider slot.
/// Rows take their tallest card, so an open card's neighbours grow with
/// it rather than leaving a ragged row.
struct LauncherRowLayout: Layout {
    var columns: Int
    var spacing: CGFloat
    var expandedIndex: Int?

    private struct Slot {
        var index: Int
        var frame: CGRect
    }

    /// Lay the subviews into frames for `width`, returning them and the
    /// total height.
    private func slots(width: CGFloat, subviews: Subviews) -> ([Slot], CGFloat) {
        let columns = max(1, columns)
        let slotWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let expandedSpan = min(2, columns)
        var placed: [Slot] = []
        // The row being filled: which subview, its first column, how many
        // columns it spans, and its measured height at that width.
        var row: [(index: Int, column: Int, span: Int, height: CGFloat)] = []
        var column = 0
        var y: CGFloat = 0

        func widthFor(span: Int) -> CGFloat {
            slotWidth * CGFloat(span) + spacing * CGFloat(span - 1)
        }
        func flushRow() {
            guard !row.isEmpty else { return }
            let height = row.map(\.height).max() ?? 0
            for item in row {
                let x = CGFloat(item.column) * (slotWidth + spacing)
                placed.append(Slot(index: item.index,
                                   frame: CGRect(x: x, y: y, width: widthFor(span: item.span),
                                                 height: height)))
            }
            y += height + spacing
            row.removeAll()
            column = 0
        }
        func place(_ index: Int, span: Int) {
            if column + span > columns { flushRow() }
            let height = subviews[index].sizeThatFits(
                ProposedViewSize(width: widthFor(span: span), height: nil)).height
            row.append((index, column, span, height))
            column += span
        }

        // Reading order, except that a card the open one displaces from its
        // own row is dealt again right after it.
        var queue = Array(subviews.indices)
        var i = 0
        while i < queue.count {
            let index = queue[i]
            i += 1
            if index == expandedIndex {
                // The card's own slot first: a full row wraps before it,
                // as it would for the closed card.
                if column >= columns { flushRow() }
                // Open in place, out from under the thumb: right of centre
                // the card grows leftward over its neighbour (and a card
                // whose span would overrun the row has to anyway); the
                // covered cards are dealt again right after it, so the
                // left neighbour shuffles down and the open card stays put.
                let rightHalf = column * 2 > columns - 1
                let pullBack = rightHalf
                    ? min(column, expandedSpan - 1)
                    : max(0, column + expandedSpan - columns)
                if pullBack > 0 {
                    let displaced = row.suffix(pullBack).map(\.index)
                    row.removeLast(pullBack)
                    column -= pullBack
                    queue.insert(contentsOf: displaced, at: i)
                }
                place(index, span: expandedSpan)
            } else {
                place(index, span: 1)
            }
        }
        flushRow()
        return (placed, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let (_, height) = slots(width: width, subviews: subviews)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (placed, _) = slots(width: bounds.width, subviews: subviews)
        for slot in placed {
            let frame = slot.frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
            subviews[slot.index].place(at: frame.origin,
                                       proposal: ProposedViewSize(frame.size))
        }
    }
}
/// The iPhone home (#124): `LauncherSurface` under a navigation title, with
/// the section routes in a trailing menu — the compact-width counterpart of
/// the iPad split root's buttons-below-the-launcher (#126).
package struct IOSLauncherHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    @State private var showReorder = false

    package init() {}

    package var body: some View {
        NavigationStack {
            LauncherSurface()
                .navigationTitle("Moment Tally")
                .toolbar {
                    // Palm Springs when the build carries the injected fonts —
                    // same degrade-to-system rule as everywhere else.
                    if let script = Brand.script(26) {
                        ToolbarItem(placement: .principal) {
                            Text("Moment Tally").font(script)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showReorder = true
                            } label: {
                                Label("Reorder Tallies", systemImage: "arrow.up.arrow.down")
                            }
                            .disabled(model.tagSets.count < 2)
                            Divider()
                            Button {
                                openAppSection(.tagSets)
                            } label: {
                                Label("Tallies", systemImage: "square.grid.2x2")
                            }
                            Button {
                                openAppSection(.review)
                            } label: {
                                Label("Review", systemImage: "checklist")
                            }
                            Button {
                                openAppSection(.help)
                            } label: {
                                Label("Help", systemImage: "questionmark.circle")
                            }
                            Button {
                                openAppSection(.settings)
                            } label: {
                                Label("Settings", systemImage: "gear")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showReorder) {
                    IOSReorderSheet()
                }
        }
    }
}

/// Reorder as an explicit mode (#124): the Mac grid's live drag-reorder
/// fights touch scrolling, so iOS gets a native edit-mode list instead —
/// the same one shared order (there is deliberately no launcher-only
/// order), written back through the model on every move.
package struct IOSReorderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    package init() {}

    package var body: some View {
        NavigationStack {
            List {
                ForEach(model.tagSets) { set in
                    HStack(spacing: 12) {
                        LauncherTileIcon(set: set, size: 28)
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                    }
                }
                .onMove { from, to in
                    var sets = model.tagSets
                    sets.move(fromOffsets: from, toOffset: to)
                    model.tagSets = sets
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Tallies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
