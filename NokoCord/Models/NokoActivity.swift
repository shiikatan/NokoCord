import Foundation

public enum NokoActivityStatusDisplayField: String, Codable, Hashable, Sendable {
    case name
    case state
    case details
}

public enum NokoActivityType: String, Codable, Hashable, Sendable {
    case playing
    case listening
}

/// The provider-neutral activity NokoCord wants to publish.
public struct NokoActivity: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let type: NokoActivityType
    /// Optional Discord activity name override. The Social SDK may replace it
    /// with the registered application name on some Rich Presence paths.
    public let name: String?
    public let details: String?
    public let state: String?
    public let startedAt: Date?
    public let endsAt: Date?
    /// Apple-hosted image URL used for track-specific artwork.
    public let largeImageURL: String?
    /// A registered Discord application asset used when no track art is available.
    public let largeImageAssetKey: String?
    public let largeImageText: String?
    public let statusDisplayField: NokoActivityStatusDisplayField?

    public init(
        title: String,
        type: NokoActivityType = .playing,
        name: String? = nil,
        details: String? = nil,
        state: String? = nil,
        startedAt: Date? = nil,
        endsAt: Date? = nil,
        largeImageURL: String? = nil,
        largeImageAssetKey: String? = nil,
        largeImageText: String? = nil,
        statusDisplayField: NokoActivityStatusDisplayField? = nil
    ) {
        self.title = title
        self.type = type
        self.name = name
        self.details = details
        self.state = state
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.largeImageURL = largeImageURL
        self.largeImageAssetKey = largeImageAssetKey
        self.largeImageText = largeImageText
        self.statusDisplayField = statusDisplayField
    }
}

/// Identifies the app component that currently owns the published activity.
public struct NokoActivityOwner: Codable, Equatable, Hashable, Sendable {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }
}
