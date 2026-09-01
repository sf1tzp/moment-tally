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
    package let tagSet: TagSet

    package init(tagSet: TagSet) {
        self.tagSet = tagSet
    }

    package var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Spacer(minLength: 0)
            TagSetCard(set: tagSet, isPreview: true)
                .frame(width: 150)
            QuickStartRowPreview(set: tagSet)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(set.name.isEmpty ? "Untitled" : set.name)
                let tags = set.tags.filter { !$0.key.isEmpty }
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(tags) { tag in
                            TagPill(key: tag.key, value: tag.value,
                                    color: model.tagColor(for: tag.key, value: tag.value))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            let quicks = model.quickLabels(for: set)
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
