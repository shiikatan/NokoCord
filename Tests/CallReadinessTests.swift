import XCTest
@testable import NokoCordCore

final class CallReadinessTests: XCTestCase {
    func testCaptureAloneDoesNotImplyADiscordCall() {
        let readiness = assess(
            discordCallSurfaceReady: false,
            captureState: CallCaptureState(microphone: .active, camera: .none)
        )

        XCTAssertTrue(readiness.captureState.isCapturing)
        XCTAssertEqual(readiness.state, .blocked)
        XCTAssertEqual(readiness.blockers, [.discordCallSurfaceUnavailable])
        XCTAssertFalse(readiness.isCallConfirmed)
    }

    func testAllRequiredAnchorsProduceReadyStateWithoutCapture() {
        let readiness = assess()

        XCTAssertEqual(readiness.origin, "https://discord.com")
        XCTAssertTrue(readiness.mediaDevicesAvailable)
        XCTAssertEqual(readiness.microphonePermission, .granted)
        XCTAssertEqual(readiness.cameraPermission, .granted)
        XCTAssertTrue(readiness.encodedTransformAvailable)
        XCTAssertTrue(readiness.discordCallSurfaceReady)
        XCTAssertEqual(readiness.captureState, .none)
        XCTAssertEqual(readiness.blockers, [])
        XCTAssertEqual(readiness.state, .ready)
        XCTAssertFalse(readiness.isCallConfirmed)
    }

    func testCameraPermissionIsDegradedButMicrophonePermissionIsBlocking() {
        let cameraDenied = assess(cameraPermission: .denied)
        XCTAssertEqual(cameraDenied.state, .degraded)
        XCTAssertEqual(cameraDenied.blockers, [.cameraPermissionDenied])

        let microphoneDenied = assess(microphonePermission: .denied)
        XCTAssertEqual(microphoneDenied.state, .blocked)
        XCTAssertEqual(microphoneDenied.blockers, [.microphonePermissionDenied])
    }

    func testEveryPageAndTransportBlockerIsReported() {
        let readiness = assess(
            origin: "http://evil.example",
            mediaDevicesAvailable: false,
            microphonePermission: .unknown,
            cameraPermission: .notDetermined,
            encodedTransformAvailable: false,
            discordCallSurfaceReady: false
        )

        XCTAssertEqual(readiness.state, .blocked)
        XCTAssertEqual(
            readiness.blockers,
            [
                .invalidOrigin,
                .mediaDevicesUnavailable,
                .microphonePermissionUnknown,
                .cameraPermissionNotDetermined,
                .encodedTransformUnavailable,
                .discordCallSurfaceUnavailable
            ]
        )
    }

    func testDiscordOriginVariantsAreAcceptedButLookalikesAreRejected() {
        XCTAssertEqual(assess(origin: "https://discord.com").state, .ready)
        XCTAssertEqual(assess(origin: "https://discord.com:443/").state, .ready)
        XCTAssertEqual(assess(origin: "https://canary.discord.com/").state, .blocked)
        XCTAssertEqual(assess(origin: "https://discord.com.evil.example").state, .blocked)
        XCTAssertEqual(assess(origin: "https://evil.discord.com/").state, .blocked)
        XCTAssertTrue(assess(origin: "https://discord.com.evil.example").blockers.contains(.invalidOrigin))
    }

    func testCaptureStateKeepsMicrophoneAndCameraDetails() throws {
        let capture = CallCaptureState(microphone: .muted, camera: .active)
        let readiness = assess(captureState: capture)

        XCTAssertEqual(readiness.captureState, capture)
        XCTAssertTrue(readiness.captureState.isCapturing)
        XCTAssertEqual(readiness.captureState.summary, "Microphone muted, camera active")
        XCTAssertTrue(readiness.isCallConfirmed)
    }

    private func assess(
        origin: String = "https://discord.com",
        mediaDevicesAvailable: Bool = true,
        microphonePermission: CallPermissionState = .granted,
        cameraPermission: CallPermissionState = .granted,
        encodedTransformAvailable: Bool = true,
        discordCallSurfaceReady: Bool = true,
        captureState: CallCaptureState = .none
    ) -> CallReadiness {
        CallReadinessService.evaluate(
            origin: origin,
            mediaDevicesAvailable: mediaDevicesAvailable,
            microphonePermission: microphonePermission,
            cameraPermission: cameraPermission,
            encodedTransformAvailable: encodedTransformAvailable,
            discordCallSurfaceReady: discordCallSurfaceReady,
            captureState: captureState
        )
    }
}
