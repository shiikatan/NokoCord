import SwiftUI

struct FakeNitroSettingsView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(TanManager.self) private var tans
    @State private var options = NokoFakeNitroOptions()
    @State private var loaded = false
    @State private var compatibility: NokoFakeNitroCompatibility?
    private var enabled: Bool { tans.enabledIDs.contains("noko.fake-nitro") && !tans.safeMode }

    var body: some View {
        Form {
            Section("Emoji and stickers") {
                Toggle("Convert unavailable emoji", isOn: $options.enableEmojiBypass)
                Toggle("Convert unavailable stickers", isOn: $options.enableStickerBypass)
                Picker("Emoji link size", selection: $options.emojiSize) {
                    ForEach(NokoFakeNitroOptions.sizes, id: \.self) { Text("\($0) px").tag($0) }
                }
                Picker("Sticker size", selection: $options.stickerSize) {
                    ForEach(NokoFakeNitroOptions.sizes, id: \.self) { Text("\($0) px").tag($0) }
                }
                Text("Unavailable emoji and static stickers send as media links. Native-permitted items stay unchanged. Animated stickers use a GIF upload preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Links and local display") {
                Toggle("Use labeled links", isOn: $options.useHyperLinks)
                TextField("Link label", text: $options.hyperLinkText, prompt: Text("{{NAME}}"))
                Text("{{NAME}} inserts the emoji or sticker name.").font(.caption).foregroundStyle(.secondary)
                Toggle("Warn when links cannot embed", isOn: Binding(get: { !options.disableEmbedPermissionCheck }, set: { options.disableEmbedPermissionCheck = !$0 }))
                Toggle("Render emoji links as emoji", isOn: $options.transformEmojis)
                Toggle("Render sticker links as stickers", isOn: $options.transformStickers)
                Toggle("Render links in longer messages", isOn: $options.transformCompoundSentence)
                Text("Other clients may still show the original links or GIF attachments.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Client options") {
                Toggle("Discord in-app icons", isOn: $options.enableAppIcons)
                Text("Choose Discord’s home-button icon in Discord → User Settings → Appearance. NokoCord’s macOS icon is separate.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Local Discord themes", isOn: $options.enableThemes)
                Text("Choose premade themes in Discord → User Settings → Appearance. The choice stays on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Additional stream-quality choices", isOn: $options.enableStreamQualityBypass)
                Text("Discord permissions, your device, and WebKit still determine availability and output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Compatibility") {
                if !enabled {
                    Text("Enable this Tan and reload Discord to use these settings.").foregroundStyle(.secondary)
                } else if let compatibility, compatibility.active {
                    status("Emoji conversion", ready: compatibility.emoji)
                    status("Sticker conversion", ready: compatibility.sticker)
                    status("Local themes", ready: compatibility.themes)
                    status("Quality controls", ready: compatibility.stream)
                    status("Discord in-app icons", ready: compatibility.appIcons == true)
                    ForEach(compatibility.messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Reload Discord after installing or updating the Tan.").foregroundStyle(.secondary)
                }
                Button("Refresh status") { Task { compatibility = await browser.fakeNitroCompatibility() } }
            }
        }
        .formStyle(.grouped)
        .task {
            options = await browser.fakeNitroOptions()
            loaded = true
            compatibility = await browser.fakeNitroCompatibility()
        }
        .onChange(of: options) { _, value in
            guard loaded else { return }
            // Save synchronously before any view closes. Page application is
            // best effort; the same saved values run at the next document start.
            NokoFakeNitroPreferences.save(NokoFakeNitroOptions.decode(value.data))
            Task { await browser.setFakeNitroOptions(value) }
        }
    }
    private func status(_ title: String, ready: Bool) -> some View {
        LabeledContent(title, value: ready ? "Ready" : "Open the matching Discord screen")
            .font(.callout)
    }
}
