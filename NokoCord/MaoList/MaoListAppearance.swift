import SwiftUI
import WebKit

struct MLPalette {
    var accent: Color
    var background: Color
    var surface: Color
    var preset: MLThemePreset? = nil
    static func resolve(dark: Bool, custom: String, discord: MLDiscordPalette?) -> MLPalette {
        let base = MLRGB(hex: dark ? "141817" : "F6F8F6")!
        // Preserve macOS light/dark semantics even when Discord uses the other
        // appearance. Its surface contributes hue without flipping text contrast.
        let background = discord.flatMap { MLRGB(hex: $0.surface) }.map { base.mixed(with: $0, amount: 0.12) } ?? base
        let chosen = MLRGB(hex: discord?.accent ?? custom) ?? MLRGB(hex: dark ? "72CDB4" : "176D59")!
        let accent = chosen.readable(on: background, dark: dark)
        let surface = background.mixed(with: accent, amount: dark ? 0.075 : 0.025)
        func color(_ rgb: MLRGB) -> Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
        return MLPalette(accent: color(accent), background: color(background), surface: color(surface))
    }
}
private struct MLPaletteKey: EnvironmentKey { static let defaultValue = MLPalette.resolve(dark: true, custom: "", discord: nil) }
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

enum MLDiscordColors {
    /// One read on entry; no script installation, mutations or theme observers.
    @MainActor static func read(from browser: ActiveBrowserEngine) async -> MLDiscordPalette? {
        guard let view = browser.view as? WKWebView, BrowserPolicy.isDiscordOrigin(view.url) else { return nil }
        let script = """
        (() => {
          const root = document.querySelector('[class*="appMount"]') || document.body;
          if (!root) return null;
          const styles = getComputedStyle(root);
          const resolve = name => {
            const value = styles.getPropertyValue(name).trim();
            if (!value || value.includes('gradient') || value.includes('var(') || !CSS.supports('color', value)) return null;
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 1;
            const ctx = canvas.getContext('2d');
            if (!ctx) return null;
            ctx.fillStyle = '#00000000'; ctx.fillStyle = value;
            ctx.fillRect(0, 0, 1, 1);
            const rgba = ctx.getImageData(0, 0, 1, 1).data;
            if (rgba[3] < 230) return null;
            return '#' + Array.from(rgba).slice(0, 3).map(c => c.toString(16).padStart(2, '0')).join('');
          };
          return {accent: resolve('--brand-500'), surface: resolve('--background-base-lowest') || resolve('--background-primary')};
        })()
        """
        guard let value = try? await view.evaluateJavaScript(script) as? [String: String],
              let accent = value["accent"], let surface = value["surface"],
              Color(mlHex: accent) != nil, Color(mlHex: surface) != nil else { return nil }
        return MLDiscordPalette(accent: accent, surface: surface)
    }
}

struct MLAppearance: ViewModifier {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.colorScheme) private var scheme
    @AppStorage("maolistAccent") private var accent = ""
    @AppStorage("maolistCopyDiscordColors") private var copyDiscord = false
    @AppStorage("maolistThemePreset") private var presetID = ""
    func body(content: Content) -> some View {
        let preset = copyDiscord ? nil : MLThemePreset(rawValue: presetID)
        var palette = MLPalette.resolve(dark: scheme == .dark, custom: preset?.hexColors.first ?? accent, discord: copyDiscord ? runtime.discordPalette : nil)
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
    @Binding var copyDiscord: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color presets").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                ForEach(MLThemePreset.allCases) { preset in
                    Button {
                        selection = preset.rawValue
                        copyDiscord = false
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MLShiftingGradient(preset: preset).frame(height: 38).clipShape(.rect(cornerRadius: 8))
                            HStack {
                                Text(preset.name)
                                Spacer(minLength: 0)
                                if selection == preset.rawValue && !copyDiscord {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }.padding(8)
                            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selection == preset.rawValue && !copyDiscord ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(preset.name + " color preset")
                        .accessibilityAddTraits(selection == preset.rawValue && !copyDiscord ? .isSelected : [])
                }
            }
            Text("Slowly shifting gradients across MaoList. Motion pauses when inactive and respects Reduce Motion.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
