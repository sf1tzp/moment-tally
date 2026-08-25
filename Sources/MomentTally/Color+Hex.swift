import SwiftUI
import AppKit

// Traggo stores tag colors as "#rrggbb" hex strings. Bridge those to SwiftUI's
// `Color` (and back) so the tag-set editor can use a native `ColorPicker`.
extension Color {
    init?(hex: String) {
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

    /// A legible text color (black or white) to sit on top of this color.
    var contrastingTextColor: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// "#rrggbb" in sRGB, or nil if the color can't be represented there.
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
