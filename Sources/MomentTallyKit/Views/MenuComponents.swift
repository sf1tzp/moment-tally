import SwiftUI
import MomentTallyCore

/// A menu row that highlights (accent-filled, white text) on mouse-over, like
/// Rectangle's status-menu rows. Disabled rows dim and don't highlight.
package struct MenuRowButtonStyle: ButtonStyle {
    /// Off for quick-start rows: their hover treatment is an accent outline
    /// the caller draws around a larger region (button plus the
    /// hover-revealed quick-label chips), so the style must not paint its
    /// own accent fill, which would end at the button's edge.
    package var fillsOnHover = true

    package init(fillsOnHover: Bool = true) {
        self.fillsOnHover = fillsOnHover
    }

    package func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, fillsOnHover: fillsOnHover)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let fillsOnHover: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var highlighted: Bool { hovering && isEnabled && fillsOnHover }

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(highlighted ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// A small inline icon button (pencil, stop, ＋) for menu rows: secondary grey
/// at rest, stepping up to primary on a subtle backing pill on mouse-over —
/// SwiftUI's `.onHover` standing in for CSS's :hover.
package struct HoverIconButtonStyle: ButtonStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration)
    }

    private struct Icon: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var highlighted: Bool { hovering && isEnabled }

        var body: some View {
            configuration.label
                .foregroundStyle(highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(3)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// A tag shown as a colored capsule ("key: value"), colored by the tag's
/// server-side color.
package struct TagPill: View {
    package let key: String
    package let value: String
    package let color: Color

    package init(key: String, value: String, color: Color) {
        self.key = key
        self.value = value
        self.color = color
    }

    package var body: some View {
        Text(value.isEmpty ? key : "\(key): \(value)")
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(color.contrastingTextColor)
    }
}

/// One quick-label chip — "+value" in the label's color, or "+key: value"
/// (the `TagPill` spelling) with the Show-keys preference on (#186). Clicking
/// starts the set with the quick label applied, replacing the set's value for
/// the same key (see `TagSet.labels(applying:)`). Shared by the popover's
/// quick-start rows and the Launcher cards.
package struct QuickLabelChip: View {
    @Environment(AppModel.self) private var model
    package let set: TagSet
    package let quick: TagRow
    /// See `QuickLabelChipStyle.filled`.
    package var filled = false
    /// The popover routes chip starts through its quickStart so a set still
    /// carrying a value-less label opens the editor, value focused (#162).
    /// The Launcher has no editor at hand and keeps the plain-start default.
    package var start: (([SpanLabel]) async -> Void)? = nil

    package init(set: TagSet, quick: TagRow, filled: Bool = false,
                 start: (([SpanLabel]) async -> Void)? = nil) {
        self.set = set
        self.quick = quick
        self.filled = filled
        self.start = start
    }

    private var key: String { normalizeKey(quick.key) }
    private var value: String { quick.value.trimmingCharacters(in: .whitespaces) }

    package var body: some View {
        Button {
            Task {
                let labels = set.labels(applying: quick)
                if let start {
                    await start(labels)
                } else {
                    await model.start(tags: labels)
                }
            }
        } label: {
            Text(value.isEmpty ? "+\(key)"
                 : model.showQuickLabelKeys ? "+\(key): \(value)" : "+\(value)")
        }
        .buttonStyle(QuickLabelChipStyle(color: model.tagColor(for: key, value: value),
                                         filled: filled))
        .disabled(model.isBusy)
        .help("Start with \(value.isEmpty ? key : "\(key): \(value)")")
    }
}

/// A clickable capsule chip for quick labels — visually a `TagPill` that reads
/// as an action rather than a fact. Outlined in the label's color at rest,
/// filling with it on mouse-over. On busy backgrounds (the Launcher card
/// scrim) the outline is too faint, so `filled` renders the fill at rest and
/// moves the mouse-over feedback to a white ring instead.
package struct QuickLabelChipStyle: ButtonStyle {
    package let color: Color
    package var filled = false

    package init(color: Color, filled: Bool = false) {
        self.color = color
        self.filled = filled
    }

    package func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, color: color, filled: filled)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let filled: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var highlighted: Bool { hovering && isEnabled }
        private var showFill: Bool { filled || highlighted }

        /// Touch needs meat: the Mac popover's caption-sized chip is a ~17pt
        /// target, fine for a cursor, hopeless for a thumb (#124).
        private var touch: Bool {
            #if os(iOS)
            true
            #else
            false
            #endif
        }

        var body: some View {
            configuration.label
                .font(touch ? .footnote : .caption2)
                .lineLimit(1)
                .padding(.horizontal, touch ? 12 : 7)
                .padding(.vertical, touch ? 7 : 2)
                .foregroundStyle(showFill
                                 ? AnyShapeStyle(color.contrastingTextColor)
                                 : AnyShapeStyle(.primary))
                .background(Capsule().fill(showFill ? color : .clear))
                .overlay(Capsule().strokeBorder(
                    filled ? Color.white.opacity(highlighted ? 0.9 : 0) : color,
                    lineWidth: filled ? 1.5 : 1))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// Shared metrics for key: value editor rows. Every label editor (popover
/// timer editor, Tallies pane, log editor, the onboarding editors) follows
/// the same anatomy: chip-shaped color swatch, narrow key field with a "key"
/// hint, standalone colon, wide value field with a "value" hint, then a
/// borderless "+ Add Mark" button directly after the rows.
package enum LabelEditorStyle {
    /// Keys are short (`repo`, `feat`) — the value field takes the rest.
    package static let keyFieldWidth: CGFloat = 96
    /// For the 300pt popover, where 96 would leave the value field narrower
    /// than the key — this keeps the small-key / wide-value proportion of
    /// the full-width editors.
    package static let compactKeyFieldWidth: CGFloat = 72
}

/// A stand-in for `TagColorPicker`'s well — the popover picker's swatch
/// button face, and the swatch in editors that must not read or write the
/// user's palette (the walkthrough's mock editor). Sized and shaped to match
/// the native `ColorPicker` well in the window editors (Tallies, Log), a
/// 48×20 capsule, so every label-editor row reads the same.
package struct TagColorChip: View {
    package let color: Color

    package init(color: Color) {
        self.color = color
    }

    package var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Capsule().strokeBorder(.quaternary))
    }
}

/// A simple left-to-right flow layout that wraps to the next line when it runs
/// out of width — used for rows of `TagPill`s.
package struct FlowLayout: Layout {
    package var spacing: CGFloat = 4

    package init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
