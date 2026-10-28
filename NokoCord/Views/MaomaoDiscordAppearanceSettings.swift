import SwiftUI

/// Maomao's web presentation preference is separate from native Liquid Glass.
struct MaomaoDiscordAppearanceSettings: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @AppStorage(MaomaoDiscordPresentation.preferenceKey) private var enabled = true

    var body: some View {
        Toggle(isOn: $enabled) {
            SettingsControlLabel("Use Noko-Glass", explanation: "Apply NokoCord’s translucent appearance to Discord. Turn off to use Discord’s normal appearance.")
        }.onChange(of: enabled) { _, value in browser.setNokoGlassEnabled(value) }
    }
}
