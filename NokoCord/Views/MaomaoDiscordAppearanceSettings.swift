import SwiftUI

/// Maomao's web presentation preference is separate from native Liquid Glass.
struct MaomaoDiscordAppearanceSettings: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @AppStorage(MaomaoDiscordPresentation.preferenceKey) private var enabled = true

    var body: some View {
        Toggle("Noko-Glass", isOn: $enabled)
            .onChange(of: enabled) { _, value in browser.setNokoGlassEnabled(value) }
        Text("Use NokoCord’s translucent Discord presentation. Turn off for Discord’s normal appearance.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
