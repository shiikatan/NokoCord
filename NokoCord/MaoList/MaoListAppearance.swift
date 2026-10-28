import SwiftUI

struct MLPalette {
    var accent: Color
    var background: Color
    var surface: Color
    var preset: MLThemePreset? = nil
    static func resolve(dark: Bool, custom: String) -> MLPalette {
        let background = MLRGB(hex: dark ? "141817" : "F6F8F6")!
        let chosen = MLRGB(hex: custom) ?? MLRGB(hex: dark ? "72CDB4" : "176D59")!
        let accent = chosen.readable(on: background, dark: dark)
        let surface = background.mixed(with: accent, amount: dark ? 0.075 : 0.025)
        func color(_ rgb: MLRGB) -> Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
        return MLPalette(accent: color(accent), background: color(background), surface: color(surface))
    }
}
private struct MLPaletteKey: EnvironmentKey { static let defaultValue = MLPalette.resolve(dark: true, custom: "") }
extension EnvironmentValues {
    var mlPalette: MLPalette { get { self[MLPaletteKey.self] } set { self[MLPaletteKey.self] = newValue } }
}
extension Color {
    init?(mlHex: String) {
        let hex = mlHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255, opacity: 1)
    }
    var mlHex: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}

struct MLAppearance: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("maolistAccent") private var accent = ""
    @AppStorage("maolistThemePreset") private var presetID = ""
    func body(content: Content) -> some View {
        let preset = MLThemePreset(rawValue: presetID)
        var palette = MLPalette.resolve(dark: scheme == .dark, custom: preset?.hexColors.first ?? accent)
        palette.preset = preset
        return content.environment(\.mlPalette, palette).tint(palette.accent).background {
            palette.background.overlay {
                if let preset { MLShiftingGradient(preset: preset).opacity(scheme == .dark ? 0.16 : 0.10) }
            }
        }
    }
}

struct MLPanel: ViewModifier {
    @Environment(\.mlPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 16).fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : palette.surface)
                .overlay {
                    if let preset = palette.preset, !reduceTransparency {
                        MLShiftingGradient(preset: preset).opacity(0.12).clipShape(.rect(cornerRadius: 16))
                    }
                }
        }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.065)))
    }
}


// Core Animation interpolates colors without rebuilding the list on every frame.
struct MLShiftingGradient: View {
    let preset: MLThemePreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var active
    @Environment(\.nokoWorkspaceVisible) private var visible
    var body: some View {
        MLGradientLayerView(preset: preset, animated: !reduceMotion && !reduceTransparency && active != .inactive && visible)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct MLGradientLayerView: NSViewRepresentable {
    let preset: MLThemePreset
    let animated: Bool
    func makeNSView(context: Context) -> MLGradientNSView { MLGradientNSView() }
    func updateNSView(_ view: MLGradientNSView, context: Context) { view.configure(preset: preset, animated: animated) }
    static func dismantleNSView(_ view: MLGradientNSView, coordinator: ()) { view.gradient.removeAllAnimations() }
}

private final class MLGradientNSView: NSView {
    let gradient = CAGradientLayer()
    private var configuration: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = gradient
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(preset: MLThemePreset, animated: Bool) {
        let key = preset.rawValue + String(animated)
        guard configuration != key else { return }
        configuration = key
        let colors = preset.hexColors.map { NSColor(Color(mlHex: $0)!).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.removeAllAnimations()
        gradient.colors = colors
        if animated {
            let animation = CAKeyframeAnimation(keyPath: "colors")
            animation.values = [colors, [colors[1], colors[2], colors[0]], [colors[2], colors[0], colors[1]], colors]
            animation.keyTimes = [0, NSNumber(value: 1.0 / 3), NSNumber(value: 2.0 / 3), 1]
            animation.duration = 18
            animation.repeatCount = .infinity
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            gradient.add(animation, forKey: "maolist.colors")
        }
        CATransaction.commit()
    }
}

struct MLThemePresetPicker: View {
    @Binding var selection: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color presets").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                ForEach(MLThemePreset.allCases) { preset in
                    Button {
                        selection = preset.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MLShiftingGradient(preset: preset).frame(height: 38).clipShape(.rect(cornerRadius: 8))
                            HStack {
                                Text(preset.name)
                                Spacer(minLength: 0)
                                if selection == preset.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }.padding(8)
                            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selection == preset.rawValue ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(preset.name + " color preset")
                        .accessibilityAddTraits(selection == preset.rawValue ? .isSelected : [])
                }
            }
            Text("Slowly shifting gradients across MaoList. Motion pauses when inactive and respects Reduce Motion.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct MLEntryLoader: View {
    @Environment(\.mlPalette) private var palette
    let reduceMotion: Bool
    @State private var raised = false
    var body: some View {
        VStack(spacing: 16) {
            Image("MaoListMark").renderingMode(.original).resizable().scaledToFit()
                .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 16))
                .offset(y: raised ? -3 : 0)
            Text("Opening MaoList…").font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.7 : (index == 1 ? 0.55 : ((index == 0) == raised ? 1 : 0.25)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening MaoList, restoring your AniList connection")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { raised = true }
        }
        .onChange(of: reduceMotion) { _, _ in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { raised = false }
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { raised = true }
            }
        }
    }
}
