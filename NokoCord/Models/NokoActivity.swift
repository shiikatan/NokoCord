import Foundation

/// The provider-neutral activity NokoCord wants to publish.
public struct NokoActivity: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let details: String?
    public let state: String?
    public let startedAt: Date?
    public let endsAt: Date?

    public init(
        title: String,
        details: String? = nil,
        state: String? = nil,
        startedAt: Date? = nil,
        endsAt: Date? = nil
    ) {
        self.title = title
        self.details = details
        self.state = state
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

/// Identifies the app component that currently owns the published activity.
public struct NokoActivityOwner: Codable, Equatable, Hashable, Sendable {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }
}
