import SwiftUI

/// The `public` face of the brand typography for the app shells, which sit
/// outside the package boundary and cannot see `Brand` (`package` access).
/// Everything inside the package uses `Brand` directly.
public enum BrandFonts {
    /// Register the build-injected brand fonts, if any — see
    /// `Brand.registerFonts()`. Call once at app init.
    public static func register() {
        Brand.registerFonts()
    }

    /// Palm Springs live at `size`, or nil when this build carries no
    /// injected fonts — see `Brand.script(_:)`.
    public static func script(_ size: CGFloat) -> Font? {
        Brand.script(size)
    }
}
