import Foundation

enum BrowserRoute: Equatable { case workspace, external, deny }

enum BrowserPolicy {
    static let home = URL(string: "https://discord.com/app")!
    static func isDiscordOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "discord.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    static func route(_ url: URL?, isMainFrame: Bool, userActivated: Bool) -> BrowserRoute {
        guard let url, url.user == nil, url.password == nil else { return .deny }
        // This is top-level routing, not a resource or iframe domain allowlist.
        if !isMainFrame { return .workspace }
        if isDiscordOrigin(url) { return .workspace }
        if userActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .external }
        return .deny
    }
    static func permitsMediaPrompt(scheme: String, host: String, port: Int, frameURL: URL?, topURL: URL?) -> Bool {
        scheme == "https" && host.lowercased() == "discord.com" && (port == 0 || port == 443)
            && isDiscordOrigin(frameURL) && isDiscordOrigin(topURL)
    }
    static func filename(_ proposed: String) -> String {
        let name = (proposed as NSString).lastPathComponent
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
        return name.isEmpty || name == "." || name == ".." ? "Download" : String(name.prefix(180))
    }
}

enum BrowserPhase: Equatable {
    case dormant, loading, ready, failed, crashed, clearing
}

struct BrowserLifecycle: Equatable {
    private(set) var phase: BrowserPhase = .dormant
    private(set) var isVisible = false
    private(set) var isAsleep = false
    mutating func show() { isVisible = true }
    mutating func hide() { isVisible = false }
    mutating func loading() { phase = .loading }
    mutating func ready() { phase = .ready }
    mutating func fail() { phase = .failed }
    mutating func crash() { phase = .crashed }
    mutating func sleep() { isAsleep = true }
    // Wake never reloads a page or interrupts a possibly active call.
    mutating func wake() { isAsleep = false }
    mutating func clearing() { phase = .clearing }
    mutating func cleared() { phase = .dormant }
}
