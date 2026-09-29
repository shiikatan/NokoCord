import Foundation

struct CallReadinessService: Sendable {
    static func evaluate(
        origin: String,
        mediaDevicesAvailable: Bool,
        microphonePermission: CallPermissionState,
        cameraPermission: CallPermissionState,
        encodedTransformAvailable: Bool,
        discordCallSurfaceReady: Bool,
        captureState: CallCaptureState
    ) -> CallReadiness {
        var blockers: [CallReadinessBlocker] = []

        if !isSupportedDiscordOrigin(origin) {
            blockers.append(.invalidOrigin)
        }
        if !mediaDevicesAvailable {
            blockers.append(.mediaDevicesUnavailable)
        }
        if let blocker = microphoneBlocker(for: microphonePermission) {
            blockers.append(blocker)
        }
        if let blocker = cameraBlocker(for: cameraPermission) {
            blockers.append(blocker)
        }
        if !encodedTransformAvailable {
            blockers.append(.encodedTransformUnavailable)
        }
        if !discordCallSurfaceReady {
            blockers.append(.discordCallSurfaceUnavailable)
        }

        let state: CallReadinessState
        if blockers.contains(where: \.isBlocking) {
            state = .blocked
        } else if blockers.isEmpty {
            state = .ready
        } else {
            state = .degraded
        }

        return CallReadiness(
            origin: origin,
            mediaDevicesAvailable: mediaDevicesAvailable,
            microphonePermission: microphonePermission,
            cameraPermission: cameraPermission,
            encodedTransformAvailable: encodedTransformAvailable,
            discordCallSurfaceReady: discordCallSurfaceReady,
            captureState: captureState,
            blockers: blockers,
            state: state
        )
    }

    static func isSupportedDiscordOrigin(_ rawOrigin: String) -> Bool {
        guard let components = URLComponents(string: rawOrigin),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else {
            return false
        }

        // Keep call diagnostics aligned with the browser's top-level origin
        // policy. A subdomain that merely ends in discord.com is not an
        // accepted workspace origin and must not be treated as trusted here.
        return host == "discord.com"
    }

    private static func microphoneBlocker(for permission: CallPermissionState) -> CallReadinessBlocker? {
        switch permission {
        case .granted: nil
        case .denied: .microphonePermissionDenied
        case .notDetermined: .microphonePermissionNotDetermined
        case .restricted: .microphonePermissionRestricted
        case .unknown: .microphonePermissionUnknown
        }
    }

    private static func cameraBlocker(for permission: CallPermissionState) -> CallReadinessBlocker? {
        switch permission {
        case .granted: nil
        case .denied: .cameraPermissionDenied
        case .notDetermined: .cameraPermissionNotDetermined
        case .restricted: .cameraPermissionRestricted
        case .unknown: .cameraPermissionUnknown
        }
    }
}
