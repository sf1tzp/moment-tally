import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Traggo stores tag colors as "#rrggbb" hex strings. Bridge those to SwiftUI's
// `Color` (and back) so the tag-set editor can use a native `ColorPicker`.
extension Color {
    package init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        // Accept #rgb shorthand and #rrggbbaa (color pickers append alpha)
        // as well as #rrggbb. Alpha is dropped: these colors always render
        // fully opaque.
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, var v = UInt32(s, radix: 16) else { return nil }
        if s.count == 8 { v >>= 8 }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    /// sRGB components (0–1), resolved through the platform color class —
    /// the one place the AppKit/UIKit fork lives; `contrastingTextColor`,
    /// `hexString` and `Brand.hsl(of:)` all read through here. Colors that
    /// can't reach sRGB (rare — pattern/catalog colors) read as black.
    package var srgbComponents: (r: Double, g: Double, b: Double) {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return (0, 0, 0) }
        return (Double(r), Double(g), Double(b))
        #endif
    }

    /// A legible text color (black or white) to sit on top of this color.
    package var contrastingTextColor: Color {
        let (r, g, b) = srgbComponents
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }

    /// "#rrggbb" in sRGB.
    package var hexString: String? {
        let (r, g, b) = srgbComponents
        return String(format: "#%02x%02x%02x",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
