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

/// An observation is deliberately limited to a typed DOM fact. It never carries
/// a selector, node text, attribute value, or page-owned identifier.
enum DiscordProbeObservation: String, Codable, Equatable {
    case present
    case missing
    case wrongType
    case notChecked
}

enum DiscordProbeAnchor: String, CaseIterable, Codable, Hashable {
    case navigationRoot
    case channelList
    case messageList
    case messageRow
    case composer
    case attachmentControl
    case callSurface
    case notificationRegion
    case activityDispatch
}

enum DiscordProbeCapability: String, CaseIterable, Codable, Hashable {
    case mediaDevices
    case realtimeCommunication
    case notificationAPI
    case customEvents
}

struct DiscordFeatureProbeFacts: Codable, Equatable {
    let anchors: [DiscordProbeAnchor: DiscordProbeObservation]
    let capabilities: [DiscordProbeCapability: DiscordProbeObservation]

    init(
        anchors: [DiscordProbeAnchor: DiscordProbeObservation] = [:],
        capabilities: [DiscordProbeCapability: DiscordProbeObservation] = [:]
    ) {
        self.anchors = anchors
        self.capabilities = capabilities
    }

    func observation(for anchor: DiscordProbeAnchor) -> DiscordProbeObservation {
        anchors[anchor] ?? .notChecked
    }

    func observation(for capability: DiscordProbeCapability) -> DiscordProbeObservation {
        capabilities[capability] ?? .notChecked
    }
}

/// Public fallback metadata contains only a stable name, owning feature,
/// anchor, and hash. The raw hashed-class selector stays inside the probe
/// source and is never part of probe results or user-visible diagnostics.
struct DiscordSelectorFallbackMetadata: Codable, Equatable, Hashable {
    let id: String
    let feature: DiscordFeature
    let anchor: DiscordProbeAnchor
    let selectorSHA256: String
    let warning: String

    var selectorHash: String { selectorSHA256 }
}

struct DiscordProbeFacts: Codable, Equatable {
    let probeVersion: Int
    let generation: UUID
    let documentReady: Bool
    let features: [DiscordFeature: DiscordFeatureProbeFacts]
    let matchedFallbackIDs: [String]
    let timedOut: Bool
    let capturedAt: Date?

    init(
        generation: UUID,
        probeVersion: Int = 2,
        documentReady: Bool,
        features: [DiscordFeature: DiscordFeatureProbeFacts] = [:],
        matchedFallbackIDs: [String] = [],
        timedOut: Bool = false,
        capturedAt: Date? = nil
    ) {
        self.probeVersion = probeVersion
        self.generation = generation
        self.documentReady = documentReady
        self.features = features
        self.matchedFallbackIDs = matchedFallbackIDs
        self.timedOut = timedOut
        self.capturedAt = capturedAt
    }
}

enum DiscordCompatibilityReason: String, Codable, Equatable {
    case awaitingProbe
    case healthy
    case unsupportedRoute
    case documentNotReady
    case requiredAnchorMissing
    case requiredAnchorTypeMismatch
    case requiredCapabilityUnavailable
    case hashedFallbackInUse
    case probeTimedOut
    case invalidProbe

    /// Stable, sanitized copy for ordinary users. No value supplied by a page
    /// or JavaScript exception is interpolated into this text.
    var userMessage: String {
        switch self {
        case .awaitingProbe: return "Compatibility has not been checked yet."
        case .healthy: return "Compatible with this Discord surface."
        case .unsupportedRoute: return "This Discord surface is protected from Noko integrations."
        case .documentNotReady: return "Discord is still loading this surface."
        case .requiredAnchorMissing: return "A required Discord surface was not found."
        case .requiredAnchorTypeMismatch: return "A required Discord surface has an unexpected shape."
        case .requiredCapabilityUnavailable: return "This browser capability is unavailable."
        case .hashedFallbackInUse: return "A compatibility fallback is active; behavior may be reduced."
        case .probeTimedOut: return "Compatibility checking took too long and was stopped."
        case .invalidProbe: return "Compatibility data was incomplete and was ignored."
        }
    }
}

struct DiscordFeatureDiagnostic: Codable, Equatable {
    let state: DiscordFeatureState
    let reason: DiscordCompatibilityReason
    let checkedAnchorCount: Int
    let checkedCapabilityCount: Int
    let matchedFallbacks: [DiscordSelectorFallbackMetadata]

    var sanitizedMessage: String { reason.userMessage }
}

struct DiscordCompatibilitySnapshot: Codable, Equatable {
    let generation: UUID
    let route: String
    let probeVersion: Int
    let lastProbeAt: Date?
    let features: [DiscordFeature: DiscordFeatureState]
    let diagnostics: [DiscordFeature: DiscordFeatureDiagnostic]

    init(
        generation: UUID,
        route: String,
        probeVersion: Int,
        lastProbeAt: Date? = nil,
        features: [DiscordFeature: DiscordFeatureState],
        diagnostics: [DiscordFeature: DiscordFeatureDiagnostic] = [:]
    ) {
        self.generation = generation
        self.route = route
        self.probeVersion = probeVersion
        self.lastProbeAt = lastProbeAt
        self.features = features
        self.diagnostics = diagnostics
    }

    var isSupportedRoute: Bool {
        route == "app" || route == "channels" || route == "fixture"
    }

    func state(for feature: DiscordFeature) -> DiscordFeatureState {
        features[feature] ?? .unknown
    }

    func diagnostic(for feature: DiscordFeature) -> DiscordFeatureDiagnostic? {
        diagnostics[feature]
    }

    static func initial(generation: UUID = UUID()) -> Self {
        let features = Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map { ($0, DiscordFeatureState.unknown) })
        let diagnostics = Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map {
            ($0, DiscordFeatureDiagnostic(state: .unknown,
                                          reason: .awaitingProbe,
                                          checkedAnchorCount: 0,
                                          checkedCapabilityCount: 0,
                                          matchedFallbacks: []))
        })
        return Self(generation: generation,
                    route: "unknown",
                    probeVersion: 2,
                    features: features,
                    diagnostics: diagnostics)
    }
}
