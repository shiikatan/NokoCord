import Foundation
import WebKit

struct NokoFakeNitroOptions: Codable, Equatable, Sendable {
    var enableEmojiBypass = true
    var enableStickerBypass = true
    var emojiSize = 48
    var stickerSize = 160
    var transformEmojis = true
    var transformStickers = true
    var transformCompoundSentence = false
    var enableStreamQualityBypass = true
    var useHyperLinks = true
    var hyperLinkText = "{{NAME}}"
    var disableEmbedPermissionCheck = false
    var enableThemes = true
    var enableAppIcons = true

    static let sizes = [16, 32, 48, 56, 64, 96, 128, 160, 256, 512, 1024]
    static func decode(_ data: Data?) -> Self {
        var result = Self()
        guard let data, data.count <= 16 * 1024,
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] else { return result }
        var merged = defaults
        for key in defaults.keys { if let value = values[key] { merged[key] = value } }
        if let encoded = try? JSONSerialization.data(withJSONObject: merged),
           let decoded = try? JSONDecoder().decode(Self.self, from: encoded) { result = decoded }
        if !sizes.contains(result.emojiSize) { result.emojiSize = 48 }
        if !sizes.contains(result.stickerSize) { result.stickerSize = 160 }
        result.hyperLinkText = String(result.hyperLinkText.prefix(120))
        return result
    }
    var data: Data {
        let encoder = JSONEncoder()
        // Stable bytes let script installation recognize unchanged options.
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct NokoFakeNitroCompatibility: Decodable {
    var active: Bool
    var emoji: Bool
    var sticker: Bool
    var themes: Bool
    var stream: Bool
    var appIcons: Bool?
    var messages: [String]
}

/// Native controls own only FakeNitro's non-sensitive configuration. There is
/// no page-to-native privilege or generic preferences bridge.
@MainActor
enum NokoFakeNitroPreferences {
    static let storageKey = "nokoFakeNitroOptionsV1"
    static let pageStorageKey = "noko.fake-nitro.settings.v1"
    private static let sourceTag = "//# sourceURL=nokocord://fake-nitro/options.js"
    static var saved: Data? { UserDefaults.standard.data(forKey: storageKey) }
    static func save(_ options: NokoFakeNitroOptions) { UserDefaults.standard.set(options.data, forKey: storageKey) }
    static func script(_ options: NokoFakeNitroOptions) -> String {
        let json = String(data: options.data, encoding: .utf8) ?? "{}"
        return """
        (() => {
          if (location.origin !== 'https://discord.com') return;
          const options = \(json);
          try { localStorage.setItem('noko.fake-nitro.settings.v1', JSON.stringify(options)); } catch {}
          globalThis[Symbol.for('noko.fake-nitro.compat.v1')]?.updateSettings?.(options);
        })();
        \(sourceTag)
        """
    }
    static func install(on controller: WKUserContentController, enabled: Bool) {
        let previous = controller.userScripts
        let remaining = previous.filter { !$0.source.hasSuffix(sourceTag) }
        let next = enabled ? saved.map { script(NokoFakeNitroOptions.decode($0)) } : nil
        if previous.count == remaining.count, next == nil { return }
        if let next, previous.count == remaining.count + 1, previous.last?.source == next { return }
        // Preserve every other owner and its injection order. The options run
        // after the Tan at document-start, before Discord's own module loading.
        controller.removeAllUserScripts()
        for item in remaining { controller.addUserScript(item) }
        if let next { controller.addUserScript(WKUserScript(source: next, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)) }
    }
}
