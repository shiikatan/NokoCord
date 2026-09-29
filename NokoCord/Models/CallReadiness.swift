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
