import SwiftUI
import MomentTallyCore

/// The Tallies editor's preview (#179), floating above the form on the
/// window background — no section box — centred, with air before the fields
/// below: the set rendered as its two start surfaces — a Launcher card and a
/// popover Quick start row — live off the editor's binding, so edits show up
/// as they're typed. Sitting outside the form also keeps it in view while
/// the fields scroll. The card is the real `TagSetCard` in preview mode
/// (hover still reveals the quick labels, clicks are inert); the row is a
/// lookalike with the chips permanently revealed — the state the onboarding
/// walkthrough's Quick Marks page shows, since in the real popover they
/// only appear on hover.
package struct TagSetPreview: View {
    @Binding package var tagSet: TagSet
    /// Invoked by the bare preview's "+" chip — the editor appends a mark
    /// row and focuses it (#260). Nil hides the chip.
    package var onAddMark: (() -> Void)?

    package init(tagSet: Binding<TagSet>, onAddMark: (() -> Void)? = nil) {
        self._tagSet = tagSet
        self.onAddMark = onAddMark
    }

    package var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                TagSetCard(set: tagSet, isPreview: true)
                // The gradient is this card's own effect, so its switch
                // lives with the preview it changes (#260), not down the
                // form near nothing it touches. Per-card since #226 —
                // one gradient per grid read fine, a whole grid of
                // neighbouring hues did not. Unset means on.
                Toggle("Gradient", isOn: Binding(
                    get: { tagSet.gradient ?? true },
                    set: { tagSet.gradient = $0 }))
                    .font(.caption)
                    // The switch look it had in the grouped Form — out
                    // here the default resolves to a checkbox on macOS.
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("The card (and the menu's quick-start tile) takes the moment-tally.com tile gradient derived from its color. Off keeps a flat fill. Saved on this Mac.")
            }
            .frame(width: 150)
            QuickStartRowPreview(set: tagSet, onAddMark: onAddMark)
                .frame(maxWidth: 280)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

/// A popover Quick start row lookalike, mirroring `MenuContentView`'s
/// `quickStartRow` in its hovered state: accent outline on, quick-label chips
/// revealed. Metrics copy `MenuRowButtonStyle`'s label padding so the preview
/// is faithful without dragging the popover's hover-intent machinery along.
private struct QuickStartRowPreview: View {
    @Environment(AppModel.self) private var model
    let set: TagSet
    var onAddMark: (() -> Void)?

    var body: some View {
        let tags = set.tags.filter { !$0.key.isEmpty }
        let quicks = model.quickLabels(for: set)
        // With no marks and no quick marks the row would be just its name
        // in an accent outline — a dead ringer for a focused text field
        // (#260). A grey "+" chip stands where the pills will go: the
        // layout matches a populated row, and clicking it starts the
        // first mark in the editor below.
        let bare = tags.isEmpty && quicks.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(set.name.isEmpty ? "Untitled" : set.name)
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(tags) { tag in
                            TagPill(key: tag.key, value: tag.value,
                                    color: model.tagColor(for: tag.key, value: tag.value))
                        }
                    }
                } else if bare, let onAddMark {
                    Button(action: onAddMark) {
                        // TagPill's metrics in placeholder grey.
                        Text("+")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Mark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if !quicks.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(quicks) { quick in
                        // Inert start — the chips keep their hover fill so
                        // the preview demos the affordance without starting
                        // timers from the editor.
                        QuickLabelChip(set: set, quick: quick) { _ in }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .font(.callout)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 1.5))
    }
}
