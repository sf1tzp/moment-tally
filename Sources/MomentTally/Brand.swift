import SwiftUI
import AppKit
import MomentTallyCore

/// The Moment Tally brand: the wordmark — "Moment" in ink, "Tally" carrying
/// the brand gradient — plus the tally-mark brand mark (#201: four gradient
/// bars and a strike, see Resources/AppIcon.svg and the motif exports in
/// Resources/), the accent gradient and partner accents. Gradient stops are
/// the moment-tally.com values, kept verbatim so the app and the website
/// masthead read as one thing.
///
/// Typography: Palm Springs (the website's headline script) is licensed for
/// app embedding (written permission from Tom at Tropical Type, 2026-08) —
/// but its files still must never be committed here (the repo mirrors to
/// public GitHub, which would be redistribution). bundle-app.sh injects them
/// into Contents/Resources/Fonts from a private sfi/brand-assets checkout;
/// `registerFonts()` registers whatever landed there and `script` serves the
/// live face, returning nil in builds without it (the public mirror, bare
/// `swift run`) so call sites keep their system styles. Morganite Pro stays
/// image-only — its permission covers the rasterised lockup art, not the
/// font — so `display` approximates it with SF compressed-black oblique and
/// display-size spots use the PNG renders via `wordmarkLockup` /
/// `taglineLockup`.
enum Brand {

    /// The SwiftPM resource bundle. `swift build`'s generated `Bundle.module`
    /// checks only the .app root and the absolute .build path of the machine
    /// that compiled the release — on any other machine it fatalErrors before
    /// the first frame. Look where bundle-app.sh actually puts the bundle
    /// (Contents/Resources), then fall back to `.module` for unbundled
    /// `swift run` builds, where the baked-in .build path is the right one.
    /// Non-private: HelpView's acknowledgements load license texts from here.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("MomentTally_MomentTally.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    /// The display face: SF compressed black oblique — the closest system
    /// stand-in for Morganite Pro's ultra-condensed heavy oblique (the
    /// website lockup's face, licensed here as rasterised art only).
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.compressed).italic()
    }

    /// The promo face for taglines: system serif italic, the emergency
    /// stand-in for the one spot that shows Palm Springs as rasterised art
    /// (the welcome masthead) if its lockup PNG ever fails to load.
    static func promo(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif).italic()
    }

    /// Register the licensed brand fonts bundle-app.sh injected into
    /// Contents/Resources/Fonts, if any — process scope, nothing lands
    /// system-wide. Called once at app init, before any view resolves
    /// `script`; a build with no Fonts/ directory registers nothing.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Palm Springs live at `size`, or nil when this build carries no
    /// injected fonts. Call sites fall back to the sans style they'd wear
    /// anyway — deliberately not `promo`'s serif, which only ever subs for
    /// rasterised art. The script's x-height runs small, so pass a size a
    /// few points above the sans it replaces.
    static func script(_ size: CGFloat) -> Font? {
        scriptAvailable ? .custom(palmSprings, size: size) : nil
    }

    private static let palmSprings = "PalmSpringsGRAPHIC"
    /// Resolved on first use, safely after `registerFonts()` ran at init.
    private static let scriptAvailable = NSFont(name: palmSprings, size: 12) != nil

    /// "Moment Tally" as the site renders it: "Moment" in ink (whatever the
    /// context's foreground is), brand-gradient "Tally", tight tracking.
    /// A `Text` so it concatenates into sentences.
    static func wordmark(size: CGFloat) -> Text {
        let kern = -size * 0.02   // tracking-tight
        return Text("Moment ").font(display(size)).kerning(kern)
            + Text("Tally").font(display(size)).kerning(kern)
                .foregroundStyle(brandGradient)
    }

    /// The brand gradient — `linear-gradient(90deg, #007aff, #af52de,
    /// #ff2d55, #ff9500)`: blue → purple → pink → orange, horizontal, evenly
    /// spaced stops. System-palette hues that hold up on light and dark
    /// backgrounds alike, so the stops are not appearance-dependent.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: "#007aff") ?? .blue,
                Color(hex: "#af52de") ?? .purple,
                Color(hex: "#ff2d55") ?? .pink,
                Color(hex: "#ff9500") ?? .orange,
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    /// The accent gradient — `linear-gradient(135deg, #5856d6, #007aff)`:
    /// indigo into blue, top-left to bottom-right. For flourishes that
    /// should read branded without the full four-stop wordmark gradient.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: "#5856d6") ?? .indigo,
                Color(hex: "#007aff") ?? .blue,
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Traggo's accent (import attribution) — Go's Gopher Blue, nudged
    /// darker on light backgrounds where #00add8 runs out of contrast.
    static let traggoBlue = dynamic(light: "#0087a8", dark: "#00add8")

    // MARK: Launcher tile gradient (#201)

    /// The Studio launcher-tile recipe, ported verbatim from the website's
    /// `src/lib/launcher.ts` (design doc section 05): stop A is the card's
    /// color, stop B rotates hue +28° with a small saturation push and a
    /// lightness step down; low-chroma colors ramp lightness instead, so a
    /// grey tile doesn't pick up a phantom hue. CSS's 135deg is topLeading →
    /// bottomTrailing here. Keep the two files in sync.
    static func tileGradient(for color: Color) -> LinearGradient {
        let (h, s, l) = hsl(of: color)
        let stops: [Color] = s < 14
            ? [hslColor(h, s, min(l + 16, 92)), color]
            : [color, hslColor((h + 28).truncatingRemainder(dividingBy: 360),
                               min(s + 6, 96), max(l - 8, 14))]
        return LinearGradient(colors: stops,
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The recipe's glyph color: ink on light tiles, white otherwise. Only
    /// for tiles drawn with `tileGradient` — flat fills keep
    /// `contrastingTextColor`, whose threshold matches a solid background.
    static func tileGlyph(for color: Color) -> Color {
        hsl(of: color).l > 70 ? .black.opacity(0.68) : .white
    }

    /// CSS-convention HSL (h 0–360, s/l 0–100), matching the web recipe's
    /// `hexToHsl` so both ends derive the same stop B.
    private static func hsl(of color: Color) -> (h: Double, s: Double, l: Double) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0) }
        let r = Double(c.redComponent), g = Double(c.greenComponent),
            b = Double(c.blueComponent)
        let mx = max(r, g, b), mn = min(r, g, b)
        var h = 0.0, s = 0.0
        let l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
        }
        return (h, s * 100, l * 100)
    }

    private static func hslColor(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return Color(.sRGB, red: r1 + m, green: g1 + m, blue: b1 + m)
    }

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
    /// strike, monochrome — drawn in code (the favicon geometry, y flipped
    /// for AppKit) rather than shipped as an asset, so there is nothing to
    /// rasterize per scale factor. Template rendering lets the system tint it
    /// for the state it lands in (dark menu bar, highlight, reduced
    /// transparency; selected toolbar item; an accent-filled menu row).
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

    /// The inset that makes the mark read at the same size as an SF Symbol
    /// sitting beside it, tuned against the settings toolbar. One dial, so
    /// every spot that mixes the mark in with symbols stays consistent.
    static let symbolInset: CGFloat = 0.15

    /// A color that follows the appearance the view actually renders in.
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light) ?? .gray)
        })
    }
}

/// The tally mark standing in for an SF Symbol in SwiftUI, where the symbols
/// it sits beside get two things for free that a fixed `NSImage` does not:
/// they tint with `foregroundStyle` (menu rows fill accent and flip their
/// content white on hover — see `MenuRowButtonStyle`), and they scale with the
/// surrounding type. `.renderingMode(.template)` buys the first even though
/// the image already carries `isTemplate`; `@ScaledMetric` buys the second.
struct TallyMarkIcon: View {
    /// Point size at the default type size, scaled from there.
    var size: CGFloat = 14
    var inset: CGFloat = 0
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        Image(nsImage: Brand.tallyMark(size: size * scale, inset: inset))
            .renderingMode(.template)
    }
}

/// A set's launcher icon: its SF Symbol, or the brand mark when it carries
/// the reserved name. Sized in points rather than by `.font`, which reaches a
/// symbol but not an image — so both branches take the same number and land
/// at the same size, with `Brand.symbolInset` covering the optical padding
/// the mark lacks.
struct TagSetIcon: View {
    let set: TagSet
    var size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if set.symbol == TagSet.markSymbol {
            TallyMarkIcon(size: size, inset: Brand.symbolInset)
        } else {
            Image(systemName: set.symbol)
                .font(.system(size: size, weight: weight))
        }
    }
}
