import SwiftUI

/// Maomao's web presentation preference is separate from native Liquid Glass.
struct MaomaoDiscordAppearanceSettings: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @AppStorage(MaomaoDiscordPresentation.preferenceKey) private var enabled = true
    @AppStorage(MaomaoDiscordPresentation.stylePreferenceKey) private var style = NokoGlassStyle.v2.rawValue

    var body: some View {
        Group {
            Toggle(isOn: $enabled) {
                SettingsControlLabel("Use NokoGlass", explanation: "Give Discord NokoCord’s appearance. Turn off to use Discord’s normal appearance.")
            }.onChange(of: enabled) { _, value in browser.setNokoGlassEnabled(value) }
            Picker("Glass style", selection: $style) {
                ForEach(NokoGlassStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .disabled(!enabled)
            .onChange(of: style) { _, value in
                browser.setNokoGlassStyle(NokoGlassStyle(rawValue: value) ?? .v2)
            }
            Text("NokoGlass keeps the original look. NokoGlassv2 balances each theme’s colors, with clearer chat, panels, and menus. Changes apply immediately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
