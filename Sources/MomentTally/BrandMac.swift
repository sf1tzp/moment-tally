import SwiftUI
import AppKit
import MomentTallyKit

// The AppKit half of the brand (#124 split): NSImage accessors for the spots
// that need an image rather than a view — the menu bar, NSTabViewItems, the
// About masthead. The portable brand (gradients, fonts, TallyMarkShape)
// lives in MomentTallyKit/Brand.swift.
extension Brand {

    /// The tally-mark tile, from the bundled icns (works unbundled, where
    /// `NSApp.applicationIconImage` would be the generic executable icon).
    static var appIcon: NSImage? {
        resources.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
    }

    /// The wordmark as the website actually sets it — real Morganite, ink
    /// "Moment", gradient "Tally" — for display-size spots where `wordmark`'s
    /// system stand-in is most visibly not the brand face. Appearance-keyed
    /// because the renders bake their ink color in (the masters are
    /// dark-background exports); both variants regenerate from the repo-root
    /// Resources/ masters via scripts/make-lockups.swift.
    static func wordmarkLockup(for scheme: ColorScheme) -> NSImage? {
        lockup("Wordmark", scheme)
    }

    /// "Count what counts." in the real tagline face, on the same terms as
    /// `wordmarkLockup`.
    static func taglineLockup(for scheme: ColorScheme) -> NSImage? {
        lockup("Tagline", scheme)
    }

    /// The bare gradient tally motif (no icon tile) at display size, for the
    /// About masthead. Unlike the text lockups both variants are exported
    /// masters — fully gradient ink, nothing to recolor — downscaled by the
    /// same make-lockups.swift run.
    static func motif(for scheme: ColorScheme) -> NSImage? {
        lockup("Motif", scheme)
    }

    private static func lockup(_ name: String, _ scheme: ColorScheme) -> NSImage? {
        resources.url(forResource: "\(name)-\(scheme == .dark ? "dark" : "light")",
                      withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    /// The tally mark as a template image: the favicon's four bars and
    /// strike, monochrome — drawn in code (the `TallyMarkShape` geometry, y
    /// flipped for AppKit) rather than shipped as an asset, so there is
    /// nothing to rasterize per scale factor. Template rendering lets the
    /// system tint it for the state it lands in (dark menu bar, highlight,
    /// reduced transparency; selected toolbar item; an accent-filled menu
    /// row).
    ///
    /// Scale comes from the rect the handler is handed, not the nominal size,
    /// so the mark fills whatever it's asked to draw into rather than
    /// stranding 64pt geometry in a corner.
    ///
    /// Which means `size` is only a request: a handler-drawn image is
    /// size-independent, and a host that scales it to its own box (an
    /// `NSToolbarItem` does) gets a mark that redraws to fill that box at any
    /// nominal size. `inset` is the knob that survives being rescaled — the
    /// fraction of the box left empty on each edge, standing in for the
    /// optical padding SF Symbols carry inside their bounds and the mark,
    /// bleeding to its edges, does not. It reads oversized beside them at 0.
    static func tallyMark(size: CGFloat, inset: CGFloat = 0) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { rect in
            let box = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
            let place = NSAffineTransform()
            place.translateX(by: box.minX, yBy: box.minY)
            place.concat()
            let scale = NSAffineTransform()
            scale.scale(by: box.width / 64.0)
            scale.concat()
            let mark = NSBezierPath()
            for x: CGFloat in [11.25, 23.25, 35.25, 47.25] {
                mark.append(NSBezierPath(
                    roundedRect: NSRect(x: x, y: 7, width: 5.5, height: 50),
                    xRadius: 2.75, yRadius: 2.75))
            }
            // SVG's rotate(-27°) about the centre, sign flipped with the axis.
            let rotate = NSAffineTransform()
            rotate.translateX(by: 32, yBy: 32)
            rotate.rotate(byDegrees: 27)
            rotate.translateX(by: -32, yBy: -32)
            let strike = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 29.25, width: 58, height: 5.5),
                xRadius: 2.75, yRadius: 2.75)
            strike.transform(using: rotate as AffineTransform)
            mark.append(strike)
            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The mark at menu-bar size, the one spot that draws it from launch.
    static let menuBarIcon: NSImage = tallyMark(size: 18)
}
