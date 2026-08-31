import SwiftUI
import AppKit
import MomentTallyKit

// The Mac-window half of the menu/editor primitives; the portable half lives
// in MomentTallyKit/Views/MenuComponents.swift (#124). These stay here
// because they front AppKit machinery — the shared NSColorPanel and the
// window key-view loop — that has no iOS analogue.

/// A color swatch for a tag. With "color by value" on (and a non-empty
/// value) it edits the local per-`key: value` override; otherwise it edits the
/// tag key's server-side color. Disabled when the key is blank. Shared by the
/// Tag Sets settings pane and the running-timer tag editor.
struct TagColorPicker: View {
    @Environment(AppModel.self) private var model
    let key: String
    let value: String

    private var keyEmpty: Bool { key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        if model.colorTagsByValue && !value.isEmpty {
            ColorPicker("", selection: Binding(
                get: { model.tagColor(for: key, value: value) },
                set: { model.setValueColor(key: key, value: value, color: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(keyEmpty)
            .contextMenu {
                Button("Use key color") {
                    model.clearValueColor(key: key, value: value)
                }
                .disabled(model.valueColor(key: key, value: value) == nil)
            }
        } else {
            ColorPicker("", selection: Binding(
                get: { model.tagColor(for: key) },
                set: { model.scheduleTagColor(for: key, color: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(keyEmpty)
        }
    }
}

extension NSColorPanel {
    /// Close the shared color panel when the surface whose swatch opened it
    /// goes away (the settings/onboarding window closing, the popover
    /// dismissing).
    ///
    /// Every `TagColorPicker` fronts the one shared panel. When this
    /// accessory app loses its last regular window it deactivates, and AppKit
    /// hides the panel (`hidesOnDeactivate`) to re-show on the next
    /// activation — which never comes for the non-activating menu-bar
    /// popover, so a swatch click there re-fronted a window AppKit was
    /// keeping hidden (#142). A real `close()` clears that state; the next
    /// activation then opens it fresh. The `sharedColorPanelExists` guard
    /// avoids instantiating the panel just to close it.
    static func closeShared() {
        guard sharedColorPanelExists else { return }
        shared.close()
    }
}

/// Rebuilds the window's key-view loop (the Tab order) when `token` changes.
///
/// The Moment Tally window computes the loop once and never revisits it when
/// SwiftUI inserts fields later — an "+ Add Mark" row, or a whole editor
/// expanding in place — so those fields are unreachable by Tab (resizing the
/// window doesn't recompute it either). NSPopover's window evidently does
/// recalculate on its own, which is why the popover editor never shows this.
/// Attach with `refreshesKeyViewLoop(on:)`, keyed by whatever the field set
/// derives from (row counts, the selected set's id).
private struct KeyViewLoopRefresher: NSViewRepresentable {
    let token: AnyHashable

    final class Coordinator {
        var lastToken: AnyHashable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastToken != token else { return }
        context.coordinator.lastToken = token
        // After the current update commits, so the new fields are in the
        // window's view tree when the loop is recomputed.
        DispatchQueue.main.async { [weak view] in
            view?.window?.recalculateKeyViewLoop()
        }
    }
}

extension View {
    /// Recompute the containing window's Tab order whenever `token` changes
    /// (and once when this view first lands in the window).
    func refreshesKeyViewLoop(on token: some Hashable) -> some View {
        background(KeyViewLoopRefresher(token: AnyHashable(token)))
    }
}
