import Foundation

/// Models an active Discord Game Rich Presence activity received from local games/apps.
public struct GamePresence: Equatable, Sendable, Identifiable {
    public var id: String { clientId }
    public let clientId: String
    public let pid: Int?
    public var name: String
    public var details: String?
    public var state: String?
    public var type: Int // 0 = Playing, 1 = Streaming, 2 = Listening, 3 = Watching
    public var startTimestamp: Date?
    public var endTimestamp: Date?
    public var largeImageKey: String?
    public var largeImageText: String?
    public var smallImageKey: String?
    public var smallImageText: String?
    public var buttons: [[String: String]]?

    public init(
        clientId: String,
        pid: Int? = nil,
        name: String = "Game",
        details: String? = nil,
        state: String? = nil,
        type: Int = 0,
        startTimestamp: Date? = nil,
        endTimestamp: Date? = nil,
        largeImageKey: String? = nil,
        largeImageText: String? = nil,
        smallImageKey: String? = nil,
        smallImageText: String? = nil,
        buttons: [[String: String]]? = nil
    ) {
        self.clientId = clientId
        self.pid = pid
        self.name = name
        self.details = details
        self.state = state
        self.type = type
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.largeImageKey = largeImageKey
        self.largeImageText = largeImageText
        self.smallImageKey = smallImageKey
        self.smallImageText = smallImageText
        self.buttons = buttons
    }

    /// Converts the GamePresence into a Discord LOCAL_ACTIVITY_UPDATE compatible dictionary.
    ///
    /// Field bounds follow the RPC/activity contract: names, detail lines and
    /// tooltips are at most 128 characters (detail lines need at least 2), and
    /// an image is either an application asset key or an external image URL of
    /// at most 300 characters.
    public func toDiscordPayload() -> [String: Any] {
        var activity: [String: Any] = [
            "application_id": clientId,
            "name": Self.bounded(name, minimum: 1) ?? "Activity",
            "type": type,
            "flags": 1
        ]

        if let details = Self.bounded(details, minimum: 2) {
            activity["details"] = details
        }
        if let state = Self.bounded(state, minimum: 2) {
            activity["state"] = state
        }

        var timestamps: [String: Any] = [:]
        if let start = startTimestamp {
            timestamps["start"] = Int(start.timeIntervalSince1970 * 1000)
        }
        if let end = endTimestamp {
            timestamps["end"] = Int(end.timeIntervalSince1970 * 1000)
        }
        if !timestamps.isEmpty {
            activity["timestamps"] = timestamps
        }

        var assets: [String: Any] = [:]
        if let key = Self.imageKey(largeImageKey, maximum: 300) { assets["large_image"] = key }
        if let text = Self.bounded(largeImageText, minimum: 2) { assets["large_text"] = text }
        if let key = Self.imageKey(smallImageKey, maximum: 300) { assets["small_image"] = key }
        if let text = Self.bounded(smallImageText, minimum: 2) { assets["small_text"] = text }
        if !assets.isEmpty {
            activity["assets"] = assets
        }

        if let buttons = buttons, !buttons.isEmpty {
            activity["buttons"] = buttons.compactMap { $0["label"] }
            let urls = buttons.compactMap { $0["url"] }
            if !urls.isEmpty {
                activity["metadata"] = ["button_urls": urls]
            }
        }

        return activity
    }

    /// An activity image is either an application asset key, a Discord media
    /// proxy key, or an https URL. Local files cannot be fetched by Discord, so
    /// they are never sent.
    private static func imageKey(_ value: String?, maximum: Int) -> String? {
        guard let candidate = bounded(value, minimum: 1, maximum: maximum) else { return nil }
        if candidate.hasPrefix("mp:") { return candidate }
        if candidate.hasPrefix("https://") { return candidate }
        if candidate.contains("/") { return nil }
        return candidate
    }

    private static func bounded(_ value: String?, minimum: Int, maximum: Int = 128) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimum else { return nil }
        return trimmed.count <= maximum ? trimmed : String(trimmed.prefix(maximum))
    }

    public static func == (lhs: GamePresence, rhs: GamePresence) -> Bool {
        lhs.clientId == rhs.clientId &&
        lhs.name == rhs.name &&
        lhs.details == rhs.details &&
        lhs.state == rhs.state &&
        lhs.startTimestamp == rhs.startTimestamp
    }
}
