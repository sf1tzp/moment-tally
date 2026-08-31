import CoreText
import Foundation
import SwiftUI

/// The kit-side twin of the Mac app's `Brand.registerFonts()` (Brand.swift):
/// the licensed brand fonts are injected at build time from the private
/// brand-assets checkout — never committed to this repo, which mirrors to
/// public GitHub — and a build without them registers nothing and degrades
/// to system faces. On the Mac the fonts land in Contents/Resources/Fonts;
/// on iOS the build-phase script in ios/project.yml puts them in Fonts/ at
/// the bundle root. `Bundle.main.resourceURL` resolves both.
public enum BrandFonts {
    /// Register everything in the bundle's Fonts/ directory, process scope.
    /// Call once at app init, before any view resolves `script(_:)`.
    public static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Palm Springs live at `size`, or nil when this build carries no
    /// injected fonts — same contract as `Brand.script(_:)` on the Mac.
    public static func script(_ size: CGFloat) -> Font? {
        scriptAvailable ? .custom(palmSprings, size: size) : nil
    }

    private static let palmSprings = "PalmSpringsGRAPHIC"
    /// Resolved on first use, safely after `register()` ran at init. Probed
    /// through CoreText so the kit stays free of AppKit/UIKit forks.
    private static let scriptAvailable: Bool = {
        let names = CTFontManagerCopyAvailablePostScriptNames() as? [String]
        return names?.contains(palmSprings) ?? false
    }()
}
