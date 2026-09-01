import SwiftUI
import AppKit
import MomentTallyKit

// The Mac-window half of the menu/editor primitives; the portable half lives
// in MomentTallyKit/Views/MenuComponents.swift (#124/#125). This stays here
// because it fronts AppKit machinery — the shared NSColorPanel — that has
// no iOS analogue.

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
