import SwiftUI
import MomentTallyCore
import UniformTypeIdentifiers

// Live drag-to-reorder for label editor rows (#155). The editors' rows live
// in `Form` sections and popover stacks where `List.onMove` can't attach, so
// this reimplements its feel with `onDrag` + a `DropDelegate` per row: as the
// drag passes over a row, `dropEntered` moves the dragged row there and the
// others animate out of the way — the order you see mid-drag is the order a
// drop commits. The payload NSItemProvider is a formality (the drag never
// leaves the app); identity travels through the shared `dragged` binding,
// which doubles as the guard that rejects foreign drags. A drag from the
// *other* list finds no matching id, so `moveRow` refuses and nothing shuffles.

/// The drag handle heading a reorderable row. The grip alone starts the drag —
/// dragging from the text fields must keep selecting text. The preview is a
/// clear pixel: the live reshuffle is the feedback, and any real image would
/// trail the cursor with AppKit's item-count badge stuck to it.
package struct RowReorderGrip: View {
    package let tag: TagRow
    @Binding package var dragged: UUID?

    package init(tag: TagRow, dragged: Binding<UUID?>) {
        self.tag = tag
        self._dragged = dragged
    }

    package var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .help("Drag to reorder")
            .onDrag {
                dragged = tag.id
                return NSItemProvider(object: tag.id.uuidString as NSString)
            } preview: {
                Color.clear.frame(width: 1, height: 1)
            }
    }
}

private struct RowReorderDropDelegate: DropDelegate {
    let tag: TagRow
    @Binding var rows: [TagRow]
    @Binding var dragged: UUID?
    let onPerform: (() -> Void)?

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != tag.id else { return }
        withAnimation {
            _ = rows.moveRow(dragged, onto: tag.id)
        }
    }

    // .move keeps the cursor plain — no green “+” copy badge mid-drag.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        onPerform?()
        return true
    }
}

extension View {
    /// Drop half of row reordering — attach to the whole row so the shuffle
    /// triggers wherever the drag hovers, not just over the grip. `onPerform`
    /// runs once the drop lands, for editors that persist through an explicit
    /// commit funnel rather than a binding observer (the popover's).
    package func rowReorderDrop(_ tag: TagRow, rows: Binding<[TagRow]>,
                        dragged: Binding<UUID?>,
                        onPerform: (() -> Void)? = nil) -> some View {
        onDrop(of: [.text], delegate: RowReorderDropDelegate(
            tag: tag, rows: rows, dragged: dragged, onPerform: onPerform))
    }
}

/// The popover's grip: same affordance, different machinery. The MenuBarExtra
/// popover's non-activating window starts an `onDrag` session but never
/// delivers it to any `onDrop` in the same popover (verified 2026-08-04 —
/// the preview floats, no delegate callback fires), so here a plain
/// `DragGesture` drives the reshuffle instead: vertical travel in row-stride
/// units picks the target slot, and the row snaps there live. `stride` is the
/// measured row height plus the stack spacing; `onEnd` is the editor's commit.
package struct GestureReorderGrip: View {
    package let tag: TagRow
    @Binding package var rows: [TagRow]
    package let stride: CGFloat
    package let onEnd: () -> Void
    /// The dragged row's index at gesture start — translation is cumulative,
    /// so the target slot is always start + travel, immune to the reshuffles
    /// the gesture itself causes.
    @State private var startIndex: Int?

    package init(tag: TagRow, rows: Binding<[TagRow]>, stride: CGFloat,
                 onEnd: @escaping () -> Void) {
        self.tag = tag
        self._rows = rows
        self.stride = stride
        self.onEnd = onEnd
    }

    package var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .help("Drag to reorder")
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if startIndex == nil {
                            startIndex = rows.firstIndex { $0.id == tag.id }
                        }
                        guard let start = startIndex, stride > 0 else { return }
                        let delta = Int((value.translation.height / stride).rounded())
                        let target = max(0, min(rows.count - 1, start + delta))
                        if rows.firstIndex(where: { $0.id == tag.id }) != target {
                            withAnimation {
                                _ = rows.moveRow(tag.id, onto: rows[target].id)
                            }
                        }
                    }
                    .onEnded { _ in
                        startIndex = nil
                        onEnd()
                    })
    }
}
