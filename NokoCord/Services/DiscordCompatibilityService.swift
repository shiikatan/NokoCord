import Foundation

struct DiscordCompatibilityService {
    static let probeVersion = 1

    static func route(for url: URL?, origin: String) -> String {
        guard let url, let expected = URL(string: origin),
              url.scheme == expected.scheme,
              url.host == expected.host,
              effectivePort(url) == effectivePort(expected),
              url.user == nil, url.password == nil else {
            return "unknown"
        }

        guard origin == "https://discord.com" else { return "fixture" }
        if url.path == "/app" || url.path.isEmpty { return "app" }
        if url.path == "/channels" || url.path.hasPrefix("/channels/") { return "channels" }
        if url.path == "/login" || url.path.hasPrefix("/login/") { return "login" }
        if url.path == "/register" || url.path.hasPrefix("/register/") { return "auth" }
        if url.path == "/settings" || url.path.hasPrefix("/settings/") { return "settings" }
        if url.path == "/oauth2" || url.path.hasPrefix("/oauth2/") { return "oauth" }
        if url.path == "/invite" || url.path.hasPrefix("/invite/") { return "invite" }
        if url.path == "/error" || url.path.hasPrefix("/error/") { return "error" }
        return "unknown"
    }

    static func accepts(_ url: URL?, origin: String) -> Bool {
        let route = route(for: url, origin: origin)
        return route == "app" || route == "channels" || route == "fixture"
    }

    static func snapshot(for url: URL?, origin: String, generation: UUID = UUID()) -> DiscordCompatibilitySnapshot {
        let route = route(for: url, origin: origin)
        let state: DiscordFeatureState = accepts(url, origin: origin) ? .unknown : .unsupported
        return DiscordCompatibilitySnapshot(
            generation: generation,
            route: route,
            probeVersion: probeVersion,
            features: Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map { ($0, state) })
        )
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
    }
}
