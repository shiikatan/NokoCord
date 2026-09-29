import CryptoKit
import Foundation

struct DiscordCompatibilityService {
    static let probeVersion = 2
    static let probeTimeout: TimeInterval = 0.75
    static let maxProbePayloadBytes = 8 * 1024
    private static let maxMatchedFallbacks = 16

    private struct FallbackDefinition {
        let metadata: DiscordSelectorFallbackMetadata
        let selector: String

        init(
            id: String,
            feature: DiscordFeature,
            anchor: DiscordProbeAnchor,
            selector: String,
            selectorSHA256: String,
            warning: String
        ) {
            self.selector = selector
            self.metadata = DiscordSelectorFallbackMetadata(
                id: id,
                feature: feature,
                anchor: anchor,
                selectorSHA256: selectorSHA256,
                warning: warning
            )
        }
    }

    // These are intentionally named entries. The selector text is kept only
    // here to build the probe; probe facts expose the ID and hash instead.
    private static let fallbackDefinitions: [FallbackDefinition] = [
        FallbackDefinition(
            id: "messages.legacy-row-class",
            feature: .messages,
            anchor: .messageRow,
            selector: "[class^=\"message-legacy_\"]",
            selectorSHA256: "a03bc5acfb3bae90fe120c74d382e1cac35961663a5b44b4ed6c407ba3be1880",
            warning: "A legacy message-row fallback is active."
        ),
        FallbackDefinition(
            id: "composer.legacy-textarea-class",
            feature: .composer,
            anchor: .composer,
            selector: "[class*=\"channelTextArea-legacy_\"]",
            selectorSHA256: "3eae7e33e10c5dce975cc7bde34d69ee535ba1260a284ba5c983e2dcf87dac81",
            warning: "A legacy composer fallback is active."
        ),
        FallbackDefinition(
            id: "calls.legacy-panel-class",
            feature: .calls,
            anchor: .callSurface,
            selector: "[class*=\"voiceCall-legacy_\"]",
            selectorSHA256: "a662803618d677920afb2470064c2993866edfbffcba0dfe03f160968b259412",
            warning: "A legacy call-surface fallback is active."
        )
    ]

    static var fallbackMetadata: [DiscordSelectorFallbackMetadata] {
        fallbackDefinitions.map(\.metadata)
    }

    private static var fallbackDefinitionsAreHashed: Bool {
        fallbackDefinitions.allSatisfy { sha256($0.selector) == $0.metadata.selectorSHA256 }
    }

    static func route(for url: URL?, origin: String) -> String {
        guard let url,
              let expected = URL(string: origin),
              sameOrigin(url, expected),
              url.pathComponents.allSatisfy({ !$0.contains("..") }) else {
            return "unknown"
        }

        let host = expected.host?.lowercased() ?? ""
        guard expected.user == nil, expected.password == nil,
              expected.query == nil, expected.fragment == nil,
              expected.path.isEmpty || expected.path == "/" else {
            return "unknown"
        }

        let path = normalizedPath(url.path)
        if host == "fixture.invalid" {
            guard expected.scheme?.lowercased() == "https", effectivePort(expected) == 443 else {
                return "unknown"
            }
            return supportedFixtureRoute(path) ? "fixture" : protectedRoute(path)
        }

        guard host == "discord.com",
              expected.scheme?.lowercased() == "https",
              effectivePort(expected) == 443 else {
            return "unknown"
        }
        return routeForDiscordPath(path)
    }

    static func accepts(_ url: URL?, origin: String) -> Bool {
        let route = route(for: url, origin: origin)
        return route == "app" || route == "channels" || route == "fixture"
    }

    /// Returns the route-only state used while a supported document awaits its
    /// page probe. Unsupported routes are gated immediately; supported routes
    /// remain unknown so native Discord behavior is unaffected.
    static func snapshot(for url: URL?, origin: String, generation: UUID = UUID()) -> DiscordCompatibilitySnapshot {
        let route = route(for: url, origin: origin)
        guard route == "app" || route == "channels" || route == "fixture" else {
            return makeSnapshot(
                generation: generation,
                route: route,
                lastProbeAt: nil,
                state: .unsupported,
                reason: .unsupportedRoute
            )
        }
        return makeSnapshot(
            generation: generation,
            route: route,
            lastProbeAt: nil,
            state: .unknown,
            reason: .awaitingProbe
        )
    }

    /// Reduces one bounded page result. A result from an older document is
    /// ignored rather than allowed to overwrite the current document state.
    static func snapshot(
        for url: URL?,
        origin: String,
        generation: UUID,
        facts: DiscordProbeFacts,
        currentGeneration: UUID,
        now: Date = Date()
    ) -> DiscordCompatibilitySnapshot? {
        guard generation == currentGeneration, facts.generation == currentGeneration else { return nil }

        let routeSnapshot = snapshot(for: url, origin: origin, generation: currentGeneration)
        guard routeSnapshot.isSupportedRoute else { return routeSnapshot }
        guard isBounded(facts) else {
            return makeSnapshot(
                generation: currentGeneration,
                route: routeSnapshot.route,
                lastProbeAt: facts.capturedAt ?? now,
                state: .unknown,
                reason: .invalidProbe
            )
        }

        let probeTime = facts.capturedAt ?? now
        if facts.timedOut {
            return makeSnapshot(
                generation: currentGeneration,
                route: routeSnapshot.route,
                lastProbeAt: probeTime,
                state: .unknown,
                reason: .probeTimedOut
            )
        }
        guard facts.documentReady else {
            return makeSnapshot(
                generation: currentGeneration,
                route: routeSnapshot.route,
                lastProbeAt: probeTime,
                state: .unknown,
                reason: .documentNotReady
            )
        }

        var states: [DiscordFeature: DiscordFeatureState] = [:]
        var diagnostics: [DiscordFeature: DiscordFeatureDiagnostic] = [:]
        for feature in DiscordFeature.allCases {
            let result = reduce(feature: feature, facts: facts)
            states[feature] = result.state
            diagnostics[feature] = result
        }
        return DiscordCompatibilitySnapshot(
            generation: currentGeneration,
            route: routeSnapshot.route,
            probeVersion: probeVersion,
            lastProbeAt: probeTime,
            features: states,
            diagnostics: diagnostics
        )
    }

    /// A single bounded page-world probe. It reads only presence, type, and
    /// browser-capability facts. It never reads page text, form values,
    /// cookies, storage, media, or account identifiers.
    static func probeScript(for generation: UUID) -> String {
        let fallbacks = fallbackDefinitions.map { definition in
            "{id:\(quote(definition.metadata.id)), selector:\(quote(definition.selector)), hash:\(quote(definition.metadata.selectorSHA256))}"
        }.joined(separator: ",")

        return """
        (() => {
          const generation = \(quote(generation.uuidString));
          const deadline = (globalThis.performance?.now?.() ?? 0) + 200;
          let timedOut = false;
          const observe = (selector) => {
            if ((globalThis.performance?.now?.() ?? 0) > deadline) {
              timedOut = true;
              return "notChecked";
            }
            try {
              const node = document.querySelector(selector);
              return node === null ? "missing" : (node instanceof Element ? "present" : "wrongType");
            } catch (_) {
              return "missing";
            }
          };
          const capability = (value) => typeof value === "undefined" ? "missing" : "present";
          const fallbackDefinitions = [\(fallbacks)];
          const matchedFallbackIDs = fallbackDefinitions
            .filter((entry) => observe(entry.selector) === "present")
            .slice(0, 16)
            .map((entry) => entry.id);
          const anchors = {
            navigationRoot: observe('[role="navigation"], nav[aria-label]'),
            channelList: observe('[role="tree"], [aria-label*="channel" i]'),
            messageList: observe('[role="log"], [data-noko-probe="message-list"]'),
            messageRow: observe('[role="article"], [data-noko-probe="message-row"]'),
            composer: observe('[contenteditable="true"][role="textbox"], textarea[aria-label*="message" i]'),
            attachmentControl: observe('input[type="file"], button[aria-label*="attach" i]'),
            callSurface: observe('[data-noko-probe="call-surface"], [aria-label*="voice" i]'),
            notificationRegion: observe('[role="alert"], [aria-live]'),
            activityDispatch: observe('[data-noko-probe="activity-surface"], [aria-label*="activity" i]')
          };
          const capabilities = {
            mediaDevices: capability(globalThis.navigator?.mediaDevices),
            realtimeCommunication: capability(globalThis.RTCPeerConnection),
            notificationAPI: capability(globalThis.Notification),
            customEvents: capability(globalThis.CustomEvent)
          };
          const feature = (anchorNames, capabilityNames) => ({
            anchors: Object.fromEntries(anchorNames.map((name) => [name, anchors[name]])),
            capabilities: Object.fromEntries(capabilityNames.map((name) => [name, capabilities[name]]))
          });
          return {
            probeVersion: \(probeVersion),
            generation,
            documentReady: document.readyState === "complete",
            features: {
              navigation: feature(["navigationRoot", "channelList"], []),
              messages: feature(["messageList", "messageRow"], []),
              composer: feature(["composer"], []),
              media: feature(["attachmentControl"], ["mediaDevices"]),
              calls: feature(["callSurface"], ["mediaDevices", "realtimeCommunication"]),
              notifications: feature(["notificationRegion"], ["notificationAPI"]),
              activity: feature(["activityDispatch"], ["customEvents"])
            },
            matchedFallbackIDs,
            timedOut
          };
        })()
        """
    }

    private static func reduce(feature: DiscordFeature, facts: DiscordProbeFacts) -> DiscordFeatureDiagnostic {
        guard let featureFacts = facts.features[feature] else {
            return diagnostic(state: .unknown, reason: .awaitingProbe, facts: nil, matchedFallbacks: [])
        }

        let requiredAnchors = requiredAnchors(for: feature)
        let requiredCapabilities = requiredCapabilities(for: feature)
        let capabilityObservations = requiredCapabilities.map { featureFacts.observation(for: $0) }
        let matchedFallbacks = fallbackMetadata.filter {
            $0.feature == feature && facts.matchedFallbackIDs.contains($0.id)
        }
        let anchorObservations = requiredAnchors.map { anchor in
            let observation = featureFacts.observation(for: anchor)
            if observation == .missing, matchedFallbacks.contains(where: { $0.anchor == anchor }) {
                return DiscordProbeObservation.present
            }
            return observation
        }

        if anchorObservations.contains(.notChecked) || capabilityObservations.contains(.notChecked) {
            return diagnostic(state: .unknown,
                              reason: .awaitingProbe,
                              facts: featureFacts,
                              matchedFallbacks: matchedFallbacks)
        }
        if anchorObservations.contains(.wrongType) {
            return diagnostic(state: .unsupported,
                              reason: .requiredAnchorTypeMismatch,
                              facts: featureFacts,
                              matchedFallbacks: matchedFallbacks)
        }
        if anchorObservations.contains(.missing) {
            return diagnostic(state: .unsupported,
                              reason: .requiredAnchorMissing,
                              facts: featureFacts,
                              matchedFallbacks: matchedFallbacks)
        }
        if capabilityObservations.contains(.wrongType) || capabilityObservations.contains(.missing) {
            return diagnostic(state: .unsupported,
                              reason: .requiredCapabilityUnavailable,
                              facts: featureFacts,
                              matchedFallbacks: matchedFallbacks)
        }
        if !matchedFallbacks.isEmpty {
            return diagnostic(state: .degraded,
                              reason: .hashedFallbackInUse,
                              facts: featureFacts,
                              matchedFallbacks: matchedFallbacks)
        }
        return diagnostic(state: .healthy,
                          reason: .healthy,
                          facts: featureFacts,
                          matchedFallbacks: [])
    }

    private static func requiredAnchors(for feature: DiscordFeature) -> [DiscordProbeAnchor] {
        switch feature {
        case .navigation: return [.navigationRoot, .channelList]
        case .messages: return [.messageList, .messageRow]
        case .composer: return [.composer]
        case .media: return [.attachmentControl]
        case .calls: return [.callSurface]
        case .notifications: return [.notificationRegion]
        case .activity: return [.activityDispatch]
        }
    }

    private static func requiredCapabilities(for feature: DiscordFeature) -> [DiscordProbeCapability] {
        switch feature {
        case .navigation, .messages, .composer: return []
        case .media: return [.mediaDevices]
        case .calls: return [.mediaDevices, .realtimeCommunication]
        case .notifications: return [.notificationAPI]
        case .activity: return [.customEvents]
        }
    }

    private static func diagnostic(
        state: DiscordFeatureState,
        reason: DiscordCompatibilityReason,
        facts: DiscordFeatureProbeFacts?,
        matchedFallbacks: [DiscordSelectorFallbackMetadata]
    ) -> DiscordFeatureDiagnostic {
        let anchors = facts?.anchors.values.filter { $0 != .notChecked }.count ?? 0
        let capabilities = facts?.capabilities.values.filter { $0 != .notChecked }.count ?? 0
        return DiscordFeatureDiagnostic(
            state: state,
            reason: reason,
            checkedAnchorCount: anchors,
            checkedCapabilityCount: capabilities,
            matchedFallbacks: matchedFallbacks
        )
    }

    private static func makeSnapshot(
        generation: UUID,
        route: String,
        lastProbeAt: Date?,
        state: DiscordFeatureState,
        reason: DiscordCompatibilityReason
    ) -> DiscordCompatibilitySnapshot {
        let states = Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map { ($0, state) })
        let diagnostics = Dictionary(uniqueKeysWithValues: DiscordFeature.allCases.map {
            ($0, diagnostic(state: state, reason: reason, facts: nil, matchedFallbacks: []))
        })
        return DiscordCompatibilitySnapshot(
            generation: generation,
            route: route,
            probeVersion: probeVersion,
            lastProbeAt: lastProbeAt,
            features: states,
            diagnostics: diagnostics
        )
    }

    private static func isBounded(_ facts: DiscordProbeFacts) -> Bool {
        guard facts.probeVersion == probeVersion,
              let encoded = try? JSONEncoder().encode(facts),
              encoded.count <= maxProbePayloadBytes,
              fallbackDefinitionsAreHashed,
              facts.features.count <= DiscordFeature.allCases.count,
              facts.matchedFallbackIDs.count <= maxMatchedFallbacks,
              Set(facts.matchedFallbackIDs).count == facts.matchedFallbackIDs.count,
              facts.matchedFallbackIDs.allSatisfy({ id in fallbackMetadata.contains { $0.id == id } }) else {
            return false
        }
        return facts.features.values.allSatisfy { featureFacts in
            featureFacts.anchors.count <= DiscordProbeAnchor.allCases.count &&
            featureFacts.capabilities.count <= DiscordProbeCapability.allCases.count
        }
    }

    private static func sameOrigin(_ url: URL, _ expected: URL) -> Bool {
        url.scheme?.lowercased() == expected.scheme?.lowercased() &&
        url.host?.lowercased() == expected.host?.lowercased() &&
        effectivePort(url) == effectivePort(expected) &&
        url.user == nil && url.password == nil
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private static func supportedFixtureRoute(_ path: String) -> Bool {
        path == "/" || path == "/app" || path == "/channels" || path.hasPrefix("/channels/")
    }

    private static func routeForDiscordPath(_ path: String) -> String {
        if path == "/" || path == "/app" { return "app" }
        if path == "/channels" || path.hasPrefix("/channels/") { return "channels" }
        return protectedRoute(path)
    }

    private static func protectedRoute(_ path: String) -> String {
        if path == "/login" || path.hasPrefix("/login/") { return "login" }
        if path == "/register" || path.hasPrefix("/register/") { return "auth" }
        if path == "/settings" || path.hasPrefix("/settings/") { return "settings" }
        if path == "/oauth2" || path.hasPrefix("/oauth2/") { return "oauth" }
        if path == "/invite" || path.hasPrefix("/invite/") { return "invite" }
        if path == "/error" || path.hasPrefix("/error/") { return "error" }
        if path == "/download" || path.hasPrefix("/download/") { return "downloads" }
        return "unknown"
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
    }

    private static func quote(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [string])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
