import SwiftUI
import MomentTallyCore

/// The "see everything" surface complementing the popover's capped Quick start
/// list (#7): every tag set as a clickable card in a grid. Clicking a card
/// starts the set, same as a Quick start row; a running set's card stops it.
/// Dragging a card reorders the sets (#178) — there is deliberately no
/// launcher-only order: this is the one shared order, the same the Tallies
/// sidebar edits and the popover's first-N cap reads.
///
/// The reorder is a plain `DragGesture`, like the popover editor's
/// `GestureReorderGrip`, not `onDrag`/`onDrop`: a system drag session in this
/// grid flakily fails to conclude when the drop lands on the card that
/// started it — which the live reshuffle makes the common case, since the
/// dragged card parks under the cursor — and the stranded session then eats
/// the next click (verified 2026-08-05 on macbook-air). The gesture keeps
/// the same live-reshuffle feel with no session to strand. The columns are
/// computed from the width (rather than `.adaptive`) so the gesture can turn
/// cursor travel into a grid slot.
package struct LauncherView: View {
    @Environment(AppModel.self) private var model
    /// Mid-drag display order: the reshuffle animates through this draft
    /// only, so the model — and its per-mutation persist + the other
    /// surfaces reading the shared order — is written once, on drop.
    @State private var draft: [TagSet]?

    private static let minCardWidth: CGFloat = 140
    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 16
    /// One grid slot's vertical stride: the cards' `minHeight` 96 (their
    /// one-line content stays under it) plus the grid spacing.
    private static let rowStride: CGFloat = 96 + spacing

    package init() {}

    package var body: some View {
        GeometryReader { geo in
            let content = geo.size.width - Self.padding * 2
            let columns = max(1, Int((content + Self.spacing)
                                     / (Self.minCardWidth + Self.spacing)))
            let cardWidth = (content - Self.spacing * CGFloat(columns - 1))
                            / CGFloat(columns)
            ScrollView {
                // The trailing ＋ card doubles as the empty state: with no sets
                // saved, the grid is just the invitation to create one.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Self.spacing),
                                         count: columns),
                          spacing: Self.spacing) {
                    ForEach(draft ?? model.tagSets) { set in
                        // The whole card is the drag handle — unlike the
                        // editor rows there's no text selection to protect,
                        // and a click without movement still lands as a click.
                        TagSetCard(set: set, reordering: draft != nil)
                            .modifier(CardReorderGesture(
                                id: set.id, draft: $draft,
                                committed: { model.tagSets },
                                commit: { model.tagSets = $0 },
                                columns: columns,
                                columnStride: cardWidth + Self.spacing,
                                rowStride: Self.rowStride))
                    }
                    NewTagSetCard()
                }
                .padding(Self.padding)
            }
        }
    }
}

/// The 2D counterpart of `GestureReorderGrip`: cursor travel in slot-stride
/// units picks the target grid slot (columns sideways, rows of `columns`
/// vertically), and the dragged card snaps there with a springy reshuffle.
/// The origin index is captured at gesture start, so the target is always
/// start + travel, immune to the reshuffles the gesture itself causes. The
/// gesture works on the shared `draft`, seeded from the committed order on
/// first movement and handed back through `commit` on release.
private struct CardReorderGesture: ViewModifier {
    let id: UUID
    @Binding var draft: [TagSet]?
    let committed: () -> [TagSet]
    let commit: ([TagSet]) -> Void
    let columns: Int
    let columnStride: CGFloat
    let rowStride: CGFloat
    @State private var startIndex: Int?

    func body(content: Content) -> some View {
        // High priority so travel claims the events from the card's button;
        // minimumDistance keeps stationary clicks reaching it. Global
        // coordinates, deliberately: the reshuffle moves the card under the
        // cursor, and a local-space translation would shrink by every slot
        // the card itself travels.
        content.highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { value in
                    if startIndex == nil {
                        draft = committed()
                        startIndex = draft?.firstIndex { $0.id == id }
                    }
                    guard var rows = draft, let start = startIndex else { return }
                    let target = slot(for: value.translation, from: start,
                                      in: rows.count)
                    if rows.firstIndex(where: { $0.id == id }) != target {
                        _ = rows.moveRow(id, onto: rows[target].id)
                        withAnimation(.snappy(extraBounce: 0.15)) {
                            draft = rows
                        }
                    }
                }
                .onEnded { value in
                    defer { startIndex = nil }
                    guard var rows = draft, let start = startIndex else { return }
                    // Apply the release point too, not just the last
                    // onChanged — a fast tail of the event stream can outrun
                    // the updates, and the drop belongs where the cursor let
                    // go. A no-op when the reshuffle already put it there.
                    let target = slot(for: value.translation, from: start,
                                      in: rows.count)
                    _ = rows.moveRow(id, onto: rows[target].id)
                    withAnimation(.snappy(extraBounce: 0.15)) {
                        commit(rows)
                        draft = nil
                    }
                })
    }

    /// Cursor travel → grid slot: whole column-strides sideways plus whole
    /// row-strides of `columns` vertically, clamped to the array.
    private func slot(for translation: CGSize, from start: Int, in count: Int) -> Int {
        let dx = Int((translation.width / columnStride).rounded())
        let dy = Int((translation.height / rowStride).rounded())
        return max(0, min(count - 1, start + dx + dy * columns))
    }
}

/// The trailing "create" tile: dashed outline, no fill, so it reads as an
/// action rather than a set. Opens the Tag Sets pane on a fresh set.
private struct NewTagSetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    @State private var hovering = false

    var body: some View {
        Button {
            model.newTagSet()
            openAppSection(.tagSets)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 28))
                Text("New Tally")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.secondary.opacity(hovering ? 0.7 : 0.4),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Create a tally")
    }
}

/// How a touch launcher grid expands a card in place (#255): the grid owns
/// which card is open (it gives that card its whole row), the card asks to
/// open and routes its starts. Absent on the Mac, where hover intent floats
/// the chips over the card instead.
package struct CardExpansion {
    package var isExpanded: Bool
    package var expand: () -> Void
    package var collapse: () -> Void
    /// Every start from the card goes through here — the plain start and
    /// the chips' — so the grid can collapse and hand off in one place.
    package var start: ([SpanLabel]) async -> Void

    package init(isExpanded: Bool, expand: @escaping () -> Void,
                 collapse: @escaping () -> Void,
                 start: @escaping ([SpanLabel]) async -> Void) {
        self.isExpanded = isExpanded
        self.expand = expand
        self.collapse = collapse
        self.start = start
    }
}

/// One launcher card: the set's icon and name on a tile tinted with the first
/// tag's color (the set's own fallback color when it has no tags — the
/// quick-labels-only case — and accent when that isn't picked either).
/// Clicking starts the set —
/// alongside any running timers (overlapping timespans are supported). A set
/// that is itself running dims instead; hovering it reveals a stop square,
/// and clicking stops that timer. Resting on a startable card (the popover
/// rows' 180ms hover intent — a sweep or a mid-drag reshuffle doesn't count)
/// also floats the quick-label chips over it — same one-click "set plus
/// honing label" as the popover's quick-start rows.
///
/// Touch has no hover, so a card with quick labels expands on tap instead
/// (#255, via `expansion`): the tap opens the card in place with the chips
/// laid out as separate targets, and a second tap on a chip starts; a tap
/// on the open card itself only folds it back. A card without quick labels
/// starts on the one tap.
package struct TagSetCard: View {
    @Environment(AppModel.self) private var model
    package let set: TagSet
    /// The Tallies editor embeds the card as a live preview (#179): the
    /// full hover choreography stays (that's what's being previewed), but
    /// clicks are inert and the running/busy states don't leak in.
    package var isPreview = false
    /// True while the launcher grid is mid drag-reorder: the reshuffle parks
    /// the dragged card under the cursor and sweeps others past it, so the
    /// chip reveal stays suppressed until the drop.
    package var reordering = false
    /// The touch grid's expand-in-place seam (#255); nil on the Mac.
    package var expansion: CardExpansion?
    @State private var hovering = false
    /// Chips reveal on hover *intent* — the popover rows' 180ms pause — not
    /// raw hover, so a cursor sweeping the grid (or the post-drop settle)
    /// doesn't flash chips on every card it crosses.
    @State private var chipsShown = false
    @State private var chipIntent: Task<Void, Never>?

    package init(set: TagSet, isPreview: Bool = false, reordering: Bool = false,
                 expansion: CardExpansion? = nil) {
        self.set = set
        self.isPreview = isPreview
        self.reordering = reordering
        self.expansion = expansion
    }

    /// Touch platforms get standing affordances where the Mac uses hover
    /// (#124): the running card's stop scrim stays on, and quick-label
    /// chips come from the tap-to-expand face (#255) instead of hover intent.
    private static var touchIdioms: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var tint: Color { model.cardTint(for: set) }

    private var isRunning: Bool { !isPreview && model.isRunning(set) }
    private var busy: Bool { !isPreview && model.isBusy }

    private var isExpanded: Bool { expansion?.isExpanded ?? false }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                tapped()
            } label: {
                if isExpanded {
                    // The expanded identity row: icon beside the name,
                    // leading, so the chips read as belonging to it.
                    HStack(spacing: 10) {
                        TagSetIcon(set: set, size: 28)
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                } else {
                    VStack(spacing: 8) {
                        TagSetIcon(set: set, size: 28)
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)

            // The chips as their own row of full-size targets below the
            // identity, on the scrim the hover overlay uses — outside the
            // card's button so a chip tap is a chip tap, never a card tap.
            if isExpanded, let expansion {
                let quicks = model.quickLabels(for: set)
                FlowLayout(spacing: 6) {
                    ForEach(quicks) { quick in
                        QuickLabelChip(set: set, quick: quick, filled: true) {
                            await expansion.start($0)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.25)))
                .environment(\.colorScheme, .dark)
                .padding([.horizontal, .bottom], 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(set.showsGradient
                         ? Brand.tileGlyph(for: tint)
                         : tint.contrastingTextColor)
        .background(RoundedRectangle(cornerRadius: 10).fill(
            set.showsGradient
            ? AnyShapeStyle(Brand.tileGradient(for: tint))
            : AnyShapeStyle(tint)))
        .overlay {
            if isRunning && (hovering || Self.touchIdioms) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.35))
                    .allowsHitTesting(false)
                Image(systemName: "stop.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity((hovering && !busy) || isExpanded ? 0.6 : 0),
                              lineWidth: 2)
        )
        .opacity(busy || (isRunning && !hovering && !Self.touchIdioms) ? 0.5 : 1)
        // The chips are separate buttons, so they sit over the card rather
        // than nesting inside its label — on the same full-card scrim the
        // running state uses for its stop square, which also keeps them
        // readable on any tint (forcing dark resolves the chips' `.primary`
        // text to white). Clicking off a chip still starts the set plain.
        .overlay {
            let quicks = model.quickLabels(for: set)
            if chipsShown && !isRunning && !quicks.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.35))
                        .allowsHitTesting(false)
                    FlowLayout(spacing: 4) {
                        ForEach(quicks) { quick in
                            // In preview the chips keep their hover feedback
                            // but the start routes to a no-op.
                            QuickLabelChip(set: set, quick: quick, filled: true,
                                           start: chipStart)
                        }
                    }
                    .padding(8)
                }
                .environment(\.colorScheme, .dark)
            }
        }
        .onHover { inside in
            hovering = inside
            revealChips(inside)
        }
        // A drag hides chips at once; the drop restarts the intent timer if
        // the cursor is resting on this card (the dragged card's common case),
        // so chips fade in only after the spring has settled.
        .onChange(of: reordering) { _, dragging in
            revealChips(hovering && !dragging)
        }
        .help(isRunning
              ? "Stop the running timer"
              : set.labels.isEmpty
              ? "Start with no marks"
              : "Start " + set.labels.map {
                    $0.value.isEmpty ? $0.key : "\($0.key): \($0.value)"
                }.joined(separator: ", "))
    }

    /// The tap (#255): a running card stops; a startable card with quick
    /// labels and a grid that can expand it opens instead of starting, and
    /// once open the tap only folds it back — the chips are the open card's
    /// only starts; the rest — no quick labels, or the Mac — start plain.
    private func tapped() {
        guard !isPreview else { return }
        if let running = model.runningTimer(for: set) {
            Task { await model.stop(id: running.id) }
            return
        }
        if let expansion {
            if expansion.isExpanded {
                expansion.collapse()
            } else if !model.quickLabels(for: set).isEmpty {
                expansion.expand()
            } else {
                Task { await expansion.start(set.labels) }
            }
        } else {
            Task { await model.start(tagSet: set) }
        }
    }

    /// The hover overlay chips' start action: a no-op in preview, else the
    /// chip's own plain start.
    private var chipStart: (([SpanLabel]) async -> Void)? {
        isPreview ? { _ in } : nil
    }

    /// Hover-intent gate for the chip overlay, same shape as the popover
    /// rows': reveal only after the cursor rests 180ms, hide immediately.
    /// A reveal is refused outright while `reordering` — the reshuffle sets
    /// and clears hover as cards move under the stationary cursor.
    private func revealChips(_ reveal: Bool) {
        chipIntent?.cancel()
        if reveal && !reordering {
            chipIntent = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.18)) { chipsShown = true }
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) { chipsShown = false }
        }
    }
}

/// A launcher card in miniature — the same icon on the same tile treatment
/// (gradient or flat, per the card, #226) at row scale, so the popover's
/// quick-start rows read as the same objects as the Launcher grid's cards
/// (#201).
package struct LauncherTileIcon: View {
    @Environment(AppModel.self) private var model
    package let set: TagSet
    package var size: CGFloat = 22

    package init(set: TagSet, size: CGFloat = 22) {
        self.set = set
        self.size = size
    }

    package var body: some View {
        let tint = model.cardTint(for: set)
        TagSetIcon(set: set, size: size * 0.5, weight: .medium)
            .foregroundStyle(set.showsGradient
                             ? Brand.tileGlyph(for: tint)
                             : tint.contrastingTextColor)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(
                set.showsGradient
                ? AnyShapeStyle(Brand.tileGradient(for: tint))
                : AnyShapeStyle(tint)))
    }
}
