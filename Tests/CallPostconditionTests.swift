import XCTest
@testable import NokoCordCore

final class CallPostconditionTests: XCTestCase {
    func testConfirmedCallStartsActiveButBlocksNavigation() {
        let readiness = assess(captureState: CallCaptureState(microphone: .active, camera: .none))
        var teardown = CallTeardownState(readiness: readiness)

        XCTAssertEqual(teardown.phase, .active)
        XCTAssertEqual(teardown.origin, "https://discord.com")
        XCTAssertEqual(teardown.captureState, readiness.captureState)
        XCTAssertFalse(teardown.isNavigationSafe)
        XCTAssertEqual(teardown.navigationBlocker, .activeCall)
    }

    func testLeaveRequestDoesNotClearStateBeforeDiscordConfirmsIt() {
        let readiness = assess(captureState: CallCaptureState(microphone: .active, camera: .active))
        var teardown = CallTeardownState(readiness: readiness)

        teardown.requestLeave()

        XCTAssertEqual(teardown.phase, .leaveRequested)
        XCTAssertFalse(teardown.isNavigationSafe)
        XCTAssertEqual(teardown.navigationBlocker, .leavePending)
        XCTAssertTrue(teardown.captureState.isCapturing)
    }

    func testCaptureClearingBeforeDiscordConfirmationStillWaitsForThePage() {
        let readiness = assess(captureState: CallCaptureState(microphone: .active, camera: .none))
        var teardown = CallTeardownState(readiness: readiness)

        teardown.requestLeave()
        teardown.updateCaptureState(.none)

        XCTAssertEqual(teardown.phase, .leaveRequested)
        XCTAssertFalse(teardown.isNavigationSafe)
        XCTAssertEqual(teardown.navigationBlocker, .leavePending)

        teardown.confirmDiscordLeave()

        XCTAssertEqual(teardown.phase, .captureCleared)
        XCTAssertTrue(teardown.isNavigationSafe)
        XCTAssertNil(teardown.navigationBlocker)
    }

    func testDiscordConfirmationBeforeCaptureClearingStillWaitsForNativeCapture() {
        let readiness = assess(captureState: CallCaptureState(microphone: .active, camera: .none))
        var teardown = CallTeardownState(readiness: readiness)

        teardown.requestLeave()
        teardown.confirmDiscordLeave()

        XCTAssertEqual(teardown.phase, .discordLeaveConfirmed)
        XCTAssertFalse(teardown.isNavigationSafe)
        XCTAssertEqual(teardown.navigationBlocker, .captureStillActive)

        teardown.updateCaptureState(.none)

        XCTAssertEqual(teardown.phase, .captureCleared)
        XCTAssertTrue(teardown.isNavigationSafe)
    }

    func testCaptureAloneDoesNotCreateAnActiveCallButStillBlocksNavigation() {
        let readiness = assess(
            discordCallSurfaceReady: false,
            captureState: CallCaptureState(microphone: .active, camera: .none)
        )
        let teardown = CallTeardownState(readiness: readiness)

        XCTAssertEqual(teardown.phase, .idle)
        XCTAssertFalse(teardown.isCallConfirmed)
        XCTAssertFalse(teardown.isNavigationSafe)
        XCTAssertEqual(teardown.navigationBlocker, .captureStillActive)
    }

    func testPageLeaveEvidenceAdvancesAnExternalDisconnectBeforeCaptureClears() {
        let active = assess(captureState: CallCaptureState(microphone: .active, camera: .none))
        var teardown = CallTeardownState(readiness: active)

        teardown.update(readiness: assess(
            discordCallSurfaceReady: false,
            captureState: active.captureState
        ))

        XCTAssertEqual(teardown.phase, .discordLeaveConfirmed)
        XCTAssertEqual(teardown.navigationBlocker, .captureStillActive)
        XCTAssertFalse(teardown.isNavigationSafe)

        teardown.update(readiness: assess(
            discordCallSurfaceReady: false,
            captureState: .none
        ))

        XCTAssertEqual(teardown.phase, .captureCleared)
        XCTAssertTrue(teardown.isNavigationSafe)
    }

    func testLeaveControlAcceptsOnlyScopedCallLabels() {
        XCTAssertTrue(CallReadinessService.isScopedLeaveControl(label: "Leave Voice", isInsideDialog: false))
        XCTAssertTrue(CallReadinessService.isScopedLeaveControl(label: "disconnect from voice", isInsideDialog: false))
        XCTAssertTrue(CallReadinessService.isScopedLeaveControl(label: "Hang up", isInsideDialog: false))
        XCTAssertFalse(CallReadinessService.isScopedLeaveControl(label: "Disconnect", isInsideDialog: false))
        XCTAssertFalse(CallReadinessService.isScopedLeaveControl(label: "Leave Screen Share", isInsideDialog: false))
        XCTAssertFalse(CallReadinessService.isScopedLeaveControl(label: "Leave Voice", isInsideDialog: true))
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
