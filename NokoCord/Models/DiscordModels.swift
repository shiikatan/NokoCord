import Foundation

struct DiscordUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let username: String
    let globalName: String?
    let avatar: String?
    let banner: String?
    let accentColor: Int?
    let publicFlags: UInt64?
    let avatarDecorationData: DiscordAvatarDecorationData?
    let primaryGuild: DiscordPrimaryGuild?

    init(id: String, username: String, globalName: String?, avatar: String?,
         banner: String? = nil, accentColor: Int? = nil, publicFlags: UInt64? = nil,
         avatarDecorationData: DiscordAvatarDecorationData? = nil,
         primaryGuild: DiscordPrimaryGuild? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.avatar = avatar
        self.banner = banner
        self.accentColor = accentColor
        self.publicFlags = publicFlags
        self.avatarDecorationData = avatarDecorationData
        self.primaryGuild = primaryGuild
    }

    var displayName: String { globalName ?? username }
    enum CodingKeys: String, CodingKey {
        case id, username, avatar, banner
        case globalName = "global_name"
        case accentColor = "accent_color"
        case publicFlags = "public_flags"
        case avatarDecorationData = "avatar_decoration_data"
        case primaryGuild = "primary_guild"
    }
}

struct DiscordAvatarDecorationData: Codable, Equatable, Sendable {
    let asset: String
    let skuID: String
    enum CodingKeys: String, CodingKey {
        case asset
        case skuID = "sku_id"
    }
}

struct DiscordPrimaryGuild: Codable, Equatable, Sendable {
    let identityGuildID: String?
    let identityEnabled: Bool?
    let tag: String?
    let badge: String?
    enum CodingKeys: String, CodingKey {
        case tag, badge
        case identityGuildID = "identity_guild_id"
        case identityEnabled = "identity_enabled"
    }
}

struct DiscordGuild: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let icon: String?
    let owner: Bool?
    let permissions: String?
    let approximateMemberCount: Int?
    let approximatePresenceCount: Int?

    init(id: String, name: String, icon: String?, owner: Bool?, permissions: String?,
         approximateMemberCount: Int? = nil, approximatePresenceCount: Int? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.owner = owner
        self.permissions = permissions
        self.approximateMemberCount = approximateMemberCount
        self.approximatePresenceCount = approximatePresenceCount
    }

    var initials: String { String(name.split(separator: " ").prefix(2).compactMap(\.first)) }
    enum CodingKeys: String, CodingKey {
        case id, name, icon, owner, permissions
        case approximateMemberCount = "approximate_member_count"
        case approximatePresenceCount = "approximate_presence_count"
    }
}

enum ConnectionState: Equatable {
    case signedOut, authenticating, loading, connected, offline, invalidSession
    case failed(String)
    var title: String {
        switch self {
        case .signedOut: String(localized: "Signed out")
        case .authenticating: String(localized: "Waiting for authorization")
        case .loading: String(localized: "Loading account")
        case .connected: String(localized: "Account connected")
        case .offline: String(localized: "Offline")
        case .invalidSession: String(localized: "Sign in again")
        case .failed(let message): message
        }
    }
    var isBusy: Bool { self == .authenticating || self == .loading }
}

struct AccessCapability: Identifiable {
    let id: String
    let title: String
    let status: String
    let explanation: String
    static let all: [Self] = [
        .init(id: "identity", title: String(localized: "Account and servers"), status: String(localized: "OAuth setup required"), explanation: String(localized: "Standard OAuth can read your identity and basic server list. Configure your private authentication service in Settings.")),
        .init(id: "chat", title: String(localized: "Messages and channels"), status: String(localized: "Unavailable with standard OAuth"), explanation: String(localized: "A server-list grant does not grant channel history, sending, reactions, threads, forums or search.")),
        .init(id: "social", title: String(localized: "Friends and direct messages"), status: String(localized: "Discord approval required"), explanation: String(localized: "Social SDK eligibility must be confirmed for NokoCord. Its terms restrict competing products. No SDK is bundled.")),
        .init(id: "voice", title: String(localized: "Voice and DAVE"), status: String(localized: "Discord approval required"), explanation: String(localized: "No approved call transport is configured. NokoCord never starts an unencrypted fallback call.")),
        .init(id: "video", title: String(localized: "Video and screen sharing"), status: String(localized: "No supported transport"), explanation: String(localized: "Social SDK does not document video or Go Live transport. Local capture alone would not send a Discord stream."))
    ]
}
