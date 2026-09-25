import Foundation

/// Models an active Discord Game Rich Presence activity received from local games/apps.
public struct GamePresence: Equatable, Sendable, Identifiable {
    public var id: String { clientId }
    public let clientId: String
    public let pid: Int?
    public var name: String
    public var details: String?
    public var state: String?
    public var startTimestamp: Date?
    public var endTimestamp: Date?
    public var largeImageKey: String?
    public var largeImageText: String?
    public var smallImageKey: String?
    public var smallImageText: String?

    public init(
        clientId: String,
        pid: Int? = nil,
        name: String = "Game",
        details: String? = nil,
        state: String? = nil,
        startTimestamp: Date? = nil,
        endTimestamp: Date? = nil,
        largeImageKey: String? = nil,
        largeImageText: String? = nil,
        smallImageKey: String? = nil,
        smallImageText: String? = nil
    ) {
        self.clientId = clientId
        self.pid = pid
        self.name = name
        self.details = details
        self.state = state
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.largeImageKey = largeImageKey
        self.largeImageText = largeImageText
        self.smallImageKey = smallImageKey
        self.smallImageText = smallImageText
    }

    /// Converts the GamePresence into a Discord LOCAL_ACTIVITY_UPDATE compatible dictionary.
    public func toDiscordPayload() -> [String: Any] {
        var activity: [String: Any] = [
            "application_id": clientId,
            "name": name,
            "type": 0, // 0 = Playing
            "flags": 1
        ]

        if let details = details, !details.isEmpty {
            activity["details"] = details
        }
        if let state = state, !state.isEmpty {
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
        if let key = largeImageKey, !key.isEmpty { assets["large_image"] = key }
        if let text = largeImageText, !text.isEmpty { assets["large_text"] = text }
        if let key = smallImageKey, !key.isEmpty { assets["small_image"] = key }
        if let text = smallImageText, !text.isEmpty { assets["small_text"] = text }
        if !assets.isEmpty {
            activity["assets"] = assets
        }

        return activity
    }

    public static func == (lhs: GamePresence, rhs: GamePresence) -> Bool {
        lhs.clientId == rhs.clientId &&
        lhs.name == rhs.name &&
        lhs.details == rhs.details &&
        lhs.state == rhs.state &&
        lhs.startTimestamp == rhs.startTimestamp
    }
}
