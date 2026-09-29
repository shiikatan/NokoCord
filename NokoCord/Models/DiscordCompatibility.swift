import Foundation

enum DiscordFeature: String, CaseIterable, Codable, Hashable {
    case navigation
    case messages
    case composer
    case media
    case calls
    case notifications
    case activity
}

enum DiscordFeatureState: String, Codable, Equatable {
    case unknown
    case healthy
    case degraded
    case unsupported
}

struct DiscordCompatibilitySnapshot: Codable, Equatable {
    let generation: UUID
    let route: String
    let probeVersion: Int
    let features: [DiscordFeature: DiscordFeatureState]

    var isSupportedRoute: Bool {
        route == "app" || route == "channels"
    }

    func state(for feature: DiscordFeature) -> DiscordFeatureState {
        features[feature] ?? .unknown
    }

    static func initial(generation: UUID = UUID()) -> Self {
        Self(generation: generation,
             route: "unknown",
             probeVersion: 1,
             features: Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map { ($0, .unknown) }))
    }
}
