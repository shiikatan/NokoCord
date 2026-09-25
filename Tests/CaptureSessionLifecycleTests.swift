import XCTest
@testable import NokoCordCore

final class CaptureSessionLifecycleTests: XCTestCase {
    private enum Failure: Error { case configuration, start }
    private final class Backend: CaptureSessionBackend {
        var isRunning = true
        var calls: [String] = []
        var failure: Failure?
        var startsRunning = true
        func releaseResources() { calls.append("release"); isRunning = false }
        func configure() throws {
            calls.append("configure")
            if failure == .configuration { throw Failure.configuration }
        }
        func start() throws {
            calls.append("start")
            if failure == .start { throw Failure.start }
            isRunning = startsRunning
        }
    }

    func testRestartReleasesPreviousResourcesBeforeConfiguration() throws {
        let backend = Backend()
        try CaptureSessionLifecycle.start(backend)
        XCTAssertEqual(backend.calls, ["release", "configure", "start"])
        XCTAssertTrue(backend.isRunning)
    }

    func testConfigurationAndStartErrorsReleasePartialResources() {
        for failure in [Failure.configuration, .start] {
            let backend = Backend(); backend.failure = failure
            XCTAssertThrowsError(try CaptureSessionLifecycle.start(backend))
            XCTAssertEqual(backend.calls.last, "release")
            XCTAssertEqual(backend.calls.filter { $0 == "release" }.count, 2)
            XCTAssertFalse(backend.isRunning)
        }
    }

    func testFailedRestartOfReusedBackendDoesNotRetainRunningSession() throws {
        let backend = Backend()
        try CaptureSessionLifecycle.start(backend)
        backend.failure = .start
        XCTAssertThrowsError(try CaptureSessionLifecycle.start(backend))
        XCTAssertFalse(backend.isRunning)
        XCTAssertEqual(backend.calls, ["release", "configure", "start", "release", "configure", "start", "release"])
    }

    func testSilentNativeStartFailureIsAnErrorAndReleasesInput() {
        let backend = Backend(); backend.startsRunning = false
        XCTAssertThrowsError(try CaptureSessionLifecycle.start(backend)) { error in
            guard case CaptureSessionStartError.notRunning = error else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(backend.calls, ["release", "configure", "start", "release"])
        XCTAssertFalse(backend.isRunning)
    }
}
