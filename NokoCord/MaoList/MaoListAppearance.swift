import SwiftUI
import WebKit

struct MLPalette {
    var accent: Color
    var background: Color
    var surface: Color
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
    func body(content: Content) -> some View {
        let palette = MLPalette.resolve(dark: scheme == .dark, custom: accent, discord: copyDiscord ? runtime.discordPalette : nil)
        content.environment(\.mlPalette, palette).tint(palette.accent).background(palette.background)
    }
}

struct MLPanel: ViewModifier {
    @Environment(\.mlPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : palette.surface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.065)))
    }
}
