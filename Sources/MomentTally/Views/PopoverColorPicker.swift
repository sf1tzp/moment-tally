import SwiftUI
import AppKit

/// The popover's replacement for `TagColorPicker` (#13). The system
/// `ColorPicker` fronts the shared `NSColorPanel` — a floating singleton that
/// opens wherever it last was, and that the non-activating MenuBarExtra
/// window can neither position nor reliably re-front (#142). Here the swatch
/// instead opens a small picker popover anchored to its leading edge, right
/// next to the row it colors: preset swatches, an HSB wheel with a
/// brightness bar, and an eyedropper (`NSColorSampler`, which needs no
/// color panel).
///
/// Write paths match `TagColorPicker`: with "color by value" on (and a
/// non-empty value) it edits the local per-`key: value` override, otherwise
/// the tag key's server-side color. The right-click "Use key color" menu
/// for the override case carries over too. Window surfaces (Settings, Log
/// editor, Onboarding) keep `TagColorPicker` — the shared panel behaves
/// conventionally in a regular activating window.
struct PopoverTagColorPicker: View {
    @Environment(AppModel.self) private var model
    let key: String
    let value: String
    @State private var isShowingPicker = false

    private var keyEmpty: Bool { key.trimmingCharacters(in: .whitespaces).isEmpty }
    private var valueMode: Bool { model.colorTagsByValue && !value.isEmpty }

    private var selection: Binding<Color> {
        valueMode
            ? Binding(get: { model.tagColor(for: key, value: value) },
                      set: { model.setValueColor(key: key, value: value, color: $0) })
            : Binding(get: { model.tagColor(for: key) },
                      set: { model.scheduleTagColor(for: key, color: $0) })
    }

    var body: some View {
        Button {
            isShowingPicker.toggle()
        } label: {
            TagColorChip(color: selection.wrappedValue)
        }
        .buttonStyle(.plain)
        .opacity(keyEmpty ? 0.5 : 1)
        .disabled(keyEmpty)
        .help("Choose color")
        .contextMenu {
            if valueMode {
                Button("Use key color") {
                    model.clearValueColor(key: key, value: value)
                }
                .disabled(model.valueColor(key: key, value: value) == nil)
            }
        }
        .popover(isPresented: $isShowingPicker, arrowEdge: .leading) {
            ColorPickerPanel(selection: selection)
        }
    }
}

/// The anchored picker: preset grid on top (the fast common case), wheel and
/// brightness bar below it, eyedropper alongside.
private struct ColorPickerPanel: View {
    let selection: Binding<Color>

    // The wheel edits local HSB state, seeded from the bound color when the
    // popover opens. Round-tripping every drag tick through the binding would
    // quantise hue/sat via the stored hex and make the thumb jitter (a grey
    // resolves to hue 0, snapping the thumb to 3 o'clock mid-drag).
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var brightness = 1.0
    // Must outlive the async magnifier session or the callback never fires.
    @State private var sampler = NSColorSampler()

    /// Warm-to-cool through the persona palette (#201 — the website
    /// launcher.ts hexes), with traggo blue (#00add8) and the app's default
    /// tag blue (#2196f3) keeping their seats.
    private static let presets = [
        "#ff9500", "#f7b060", "#d84315", "#ff2d55",
        "#ec407a", "#f06292", "#af52de", "#5856d6",
        "#007aff", "#2196f3", "#42a5f5", "#30b0c7",
        "#00add8", "#26a69a", "#34c759", "#66bb6a",
    ]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 8),
                      spacing: 4) {
                ForEach(Self.presets, id: \.self) { hex in
                    preset(hex)
                }
            }
            ColorWheel(hue: $hue, saturation: $saturation, brightness: brightness,
                       onChange: commit)
            HStack(spacing: 8) {
                BrightnessBar(hue: hue, saturation: saturation, brightness: $brightness,
                              onChange: commit)
                Button {
                    sampler.show { picked in
                        guard let picked else { return }
                        seed(from: Color(nsColor: picked))
                        commit()
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.borderless)
                .help("Pick color from screen")
            }
        }
        .padding(12)
        .onAppear { seed(from: selection.wrappedValue) }
    }

    private func preset(_ hex: String) -> some View {
        let color = Color(hex: hex) ?? .clear
        let selected = selection.wrappedValue.hexString == hex
        return Button {
            seed(from: color)
            selection.wrappedValue = color
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary),
                                  lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    private func commit() {
        selection.wrappedValue = Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private func seed(from color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        hue = h; saturation = s; brightness = b
    }
}

/// Hue/saturation disc: hue is the angle, saturation the radius, like the
/// system picker's wheel. Drawn as an angular hue sweep under a white
/// radial wash (desaturation towards the centre) under a black veil for the
/// current brightness, so the wheel always previews achievable colors.
private struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    let brightness: Double
    let onChange: () -> Void

    private static let diameter: CGFloat = 148
    private var radius: CGFloat { Self.diameter / 2 }

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(
                // 13 stops so the sweep ends where it starts (hue wraps).
                gradient: Gradient(colors: (0...12).map {
                    Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
                }),
                center: .center))
            Circle().fill(RadialGradient(
                gradient: Gradient(colors: [.white, .white.opacity(0)]),
                center: .center, startRadius: 0, endRadius: radius))
            Circle().fill(Color.black.opacity(1 - brightness))
            Circle()
                .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(radius: 1)
                .offset(x: cos(hue * 2 * .pi) * saturation * radius,
                        y: sin(hue * 2 * .pi) * saturation * radius)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { pick($0.location) })
    }

    /// Both the angular gradient and `atan2` here run clockwise from
    /// 3 o'clock in view space (y down), so the picked hue matches the pixel
    /// under the cursor; the thumb offset above uses the same convention.
    private func pick(_ location: CGPoint) {
        let dx = location.x - radius, dy = location.y - radius
        saturation = min(sqrt(dx * dx + dy * dy) / radius, 1)
        let turn = atan2(dy, dx) / (2 * .pi)
        hue = (turn + 1).truncatingRemainder(dividingBy: 1)
        onChange()
    }
}

/// Brightness as a black-to-full-brightness gradient capsule with a
/// draggable thumb, matching the wheel's current hue/saturation.
private struct BrightnessBar: View {
    let hue: Double
    let saturation: Double
    @Binding var brightness: Double
    let onChange: () -> Void

    private static let height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - Self.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: [.black, Color(hue: hue, saturation: saturation, brightness: 1)],
                        startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.quaternary))
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(radius: 1)
                    .frame(width: Self.height, height: Self.height)
                    .offset(x: brightness * travel)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                brightness = min(max((drag.location.x - Self.height / 2) / travel, 0), 1)
                onChange()
            })
        }
        .frame(height: Self.height)
    }
}
