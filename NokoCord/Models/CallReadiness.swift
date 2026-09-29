import Foundation

enum CallPermissionState: String, Codable, CaseIterable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown
}

enum CallMediaCaptureState: String, Codable, CaseIterable, Sendable {
    case none
    case active
    case muted
}

struct CallCaptureState: Codable, Equatable, Sendable {
    let microphone: CallMediaCaptureState
    let camera: CallMediaCaptureState

    static let none = CallCaptureState(microphone: .none, camera: .none)

    var isCapturing: Bool {
        microphone != .none || camera != .none
    }

    var summary: String {
        switch (microphone, camera) {
        case (.none, .none): "No media capture"
        case (.active, .none): "Microphone active"
        case (.muted, .none): "Microphone muted"
        case (.none, .active): "Camera active"
        case (.none, .muted): "Camera muted"
        case (.active, .active): "Microphone and camera active"
        case (.active, .muted): "Microphone active, camera muted"
        case (.muted, .active): "Microphone muted, camera active"
        case (.muted, .muted): "Microphone and camera muted"
        }
    }
}

enum CallReadinessBlocker: String, Codable, CaseIterable, Hashable, Sendable {
    case invalidOrigin
    case mediaDevicesUnavailable
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case microphonePermissionRestricted
    case microphonePermissionUnknown
    case cameraPermissionDenied
    case cameraPermissionNotDetermined
    case cameraPermissionRestricted
    case cameraPermissionUnknown
    case encodedTransformUnavailable
    case discordCallSurfaceUnavailable

    /// Camera access is useful but optional for an audio call. Every other
    /// blocker prevents the app from claiming that the call prerequisites are
    /// available.
    var isBlocking: Bool {
        switch self {
        case .cameraPermissionDenied,
             .cameraPermissionNotDetermined,
             .cameraPermissionRestricted,
             .cameraPermissionUnknown:
            false
        default:
            true
        }
    }

    var title: String {
        switch self {
        case .invalidOrigin: "Discord origin could not be verified"
        case .mediaDevicesUnavailable: "Media devices are unavailable"
        case .microphonePermissionDenied: "Microphone access is denied"
        case .microphonePermissionNotDetermined: "Microphone access needs approval"
        case .microphonePermissionRestricted: "Microphone access is restricted"
        case .microphonePermissionUnknown: "Microphone access could not be checked"
        case .cameraPermissionDenied: "Camera access is denied"
        case .cameraPermissionNotDetermined: "Camera access needs approval"
        case .cameraPermissionRestricted: "Camera access is restricted"
        case .cameraPermissionUnknown: "Camera access could not be checked"
        case .encodedTransformUnavailable: "Discord media encryption is unavailable"
        case .discordCallSurfaceUnavailable: "The Discord call surface is not ready"
        }
    }
}

enum CallReadinessState: String, Codable, Sendable {
    case ready
    case degraded
    case blocked
}

struct CallReadiness: Codable, Equatable, Sendable {
    let origin: String
    let mediaDevicesAvailable: Bool
    let microphonePermission: CallPermissionState
    let cameraPermission: CallPermissionState
    let encodedTransformAvailable: Bool
    let discordCallSurfaceReady: Bool
    let captureState: CallCaptureState
    let blockers: [CallReadinessBlocker]
    let state: CallReadinessState

    var isReadyToJoin: Bool {
        state != .blocked
    }

    /// A call can only be considered confirmed when the page has reported its
    /// call surface as ready and capture is present. Capture by itself never
    /// establishes this value.
    var isCallConfirmed: Bool {
        state != .blocked && discordCallSurfaceReady && captureState.isCapturing
    }
}

/// The native side of a leave request is deliberately a postcondition state
/// machine. A page click is only a request; navigation becomes safe after the
/// page confirms that its Discord call surface left and WebKit reports that
/// native capture is gone.
enum CallTeardownPhase: String, Codable, Equatable, Sendable {
    case idle
    case active
    case leaveRequested
    case discordLeaveConfirmed
    case captureCleared
}

enum CallNavigationBlocker: String, Codable, Equatable, Sendable {
    case activeCall
    case leavePending
    case captureStillActive

    var title: String {
        switch self {
        case .activeCall: "An active Discord call is still present"
        case .leavePending: "Waiting for Discord to confirm that the call ended"
        case .captureStillActive: "Waiting for native media capture to stop"
        }
    }
}

struct CallTeardownState: Equatable, Sendable {
    let origin: String
    private(set) var phase: CallTeardownPhase
    private(set) var captureState: CallCaptureState

    init(readiness: CallReadiness) {
        origin = readiness.origin
        captureState = readiness.captureState
        phase = readiness.isCallConfirmed ? .active : .idle
    }

    var isCallConfirmed: Bool {
        phase == .active || phase == .leaveRequested
    }

    var isNavigationSafe: Bool {
        navigationBlocker == nil
    }

    var navigationBlocker: CallNavigationBlocker? {
        switch phase {
        case .idle:
            return captureState.isCapturing ? .captureStillActive : nil
        case .active:
            return .activeCall
        case .leaveRequested:
            return .leavePending
        case .discordLeaveConfirmed:
            return .captureStillActive
        case .captureCleared:
            return captureState.isCapturing ? .captureStillActive : nil
        }
    }

    mutating func requestLeave() {
        guard phase == .active else { return }
        phase = .leaveRequested
    }

    mutating func confirmDiscordLeave() {
        guard phase == .leaveRequested else { return }
        phase = captureState == .none ? .captureCleared : .discordLeaveConfirmed
    }

    mutating func updateCaptureState(_ state: CallCaptureState) {
        captureState = state
        guard state == .none else { return }
        if phase == .discordLeaveConfirmed {
            phase = .captureCleared
        }
    }

    /// Reconciles a fresh, bounded readiness result with the teardown state.
    /// Losing the verified Discord call surface is the page-side postcondition;
    /// native capture must still clear before navigation is released.
    mutating func update(readiness: CallReadiness) {
        captureState = readiness.captureState

        switch phase {
        case .idle, .captureCleared:
            if readiness.isCallConfirmed {
                phase = .active
            }
        case .active, .leaveRequested:
            guard !readiness.discordCallSurfaceReady else { return }
            phase = captureState == .none ? .captureCleared : .discordLeaveConfirmed
        case .discordLeaveConfirmed:
            if captureState == .none {
                phase = .captureCleared
            }
        }
    }
}
