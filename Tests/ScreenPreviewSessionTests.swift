import XCTest
@testable import NokoCordCore

private enum PreviewOperationError: Error {
    case failed
}

private actor PreviewOperationGate {
    private var discoveryStarted = false
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var discoverContinuation: CheckedContinuation<[String], Error>?
    private var captureContinuations: [Int: CheckedContinuation<String, Error>] = [:]
    private var captureCount = 0
    private var activeOperations = 0
    private var maximumActive = 0
    private var captureWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func discover() async throws -> [String] {
        activeOperations += 1; maximumActive = max(maximumActive, activeOperations)
        defer { activeOperations -= 1 }
        discoveryStarted = true
        discoveryWaiters.forEach { $0.resume() }; discoveryWaiters.removeAll()
        return try await withCheckedThrowingContinuation { discoverContinuation = $0 }
    }

    func waitForDiscovery() async {
        if !discoveryStarted { await withCheckedContinuation { discoveryWaiters.append($0) } }
    }

    func finishDiscover(_ result: Result<[String], Error>) {
        discoverContinuation?.resume(with: result)
        discoverContinuation = nil
    }

    func capture(_ window: String) async throws -> String {
        activeOperations += 1; maximumActive = max(maximumActive, activeOperations)
        defer { activeOperations -= 1 }
        captureCount += 1
        let number = captureCount
        let ready = captureWaiters.filter { $0.target <= number }
        captureWaiters.removeAll { $0.target <= number }
        ready.forEach { $0.continuation.resume() }
        return try await withCheckedThrowingContinuation { captureContinuations[number] = $0 }
    }

    func maximumConcurrency() -> Int { maximumActive }

    func waitForCapture(_ target: Int) async {
        guard captureCount < target else { return }
        await withCheckedContinuation { captureWaiters.append((target: target, continuation: $0)) }
    }

    func finishCapture(_ number: Int, _ result: Result<String, Error>) {
        captureContinuations.removeValue(forKey: number)?.resume(with: result)
    }
}

@MainActor
final class ScreenPreviewSessionTests: XCTestCase {
    private func makeSession(using gate: PreviewOperationGate) -> ScreenPreviewSession<String, String> {
        ScreenPreviewSession<String, String>(
            discover: { try await gate.discover() },
            capture: { window in try await gate.capture(window) }
        )
    }

    func testInitialStateHasNoOperationOrPreview() {
        let session = makeSession(using: PreviewOperationGate())

        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertNil(session.preview)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isBusy)
    }

    func testStopRejectsLateCaptureResult() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let task = session.captureWindow("window-1")
        await gate.waitForCapture(1)

        session.stop()
        await gate.finishCapture(1, .success("late-frame"))
        await task.value

        XCTAssertNil(session.preview)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.errorMessage)
    }

    func testStopRejectsLateDiscoveryResult() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let task = session.loadWindows()
        await gate.waitForDiscovery()

        session.stop()
        await gate.finishDiscover(.success(["late-window"]))
        await task.value

        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertFalse(session.isBusy)
    }

    func testSupersedingCaptureKeepsNewestResult() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let first = session.captureWindow("window-1")
        await gate.waitForCapture(1)
        let second = session.captureWindow("window-2")
        await gate.finishCapture(1, .success("old-frame"))
        await gate.waitForCapture(2)
        await gate.finishCapture(2, .success("new-frame"))
        await first.value
        await second.value

        let maximumConcurrency = await gate.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(session.preview, "new-frame")
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.errorMessage)
    }

    func testStopThenDiscoveryWaitsForUncancellableCapture() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let capture = session.captureWindow("window-1")
        await gate.waitForCapture(1)
        session.stop()
        let discovery = session.loadWindows()
        await gate.finishCapture(1, .success("discarded-frame"))
        await gate.waitForDiscovery()
        await gate.finishDiscover(.success(["new-window"]))
        await capture.value
        await discovery.value
        let maximumConcurrency = await gate.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(session.windows, ["new-window"])
        XCTAssertNil(session.preview)
    }

    func testDiscoveryCapsWindowsAndClearsPreviousFrame() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let initialCapture = session.captureWindow("window-1")
        await gate.waitForCapture(1)
        await gate.finishCapture(1, .success("existing-frame"))
        await initialCapture.value

        let task = session.loadWindows()
        XCTAssertNil(session.preview)
        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertTrue(session.isBusy)
        await gate.waitForDiscovery()
        await gate.finishDiscover(.success((0..<40).map { "window-\($0)" }))
        await task.value

        XCTAssertEqual(session.windows.count, 32)
        XCTAssertEqual(session.windows.first, "window-0")
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.isBusy)
    }

    func testCaptureFailureClearsBusyAndOldPreviewAndShowsError() async {
        let gate = PreviewOperationGate()
        let session = makeSession(using: gate)
        let initialCapture = session.captureWindow("window-1")
        await gate.waitForCapture(1)
        await gate.finishCapture(1, .success("existing-frame"))
        await initialCapture.value

        let failedCapture = session.captureWindow("window-2")
        await gate.waitForCapture(2)
        await gate.finishCapture(2, .failure(PreviewOperationError.failed))
        await failedCapture.value

        XCTAssertNil(session.preview)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.errorMessage, "A preview frame could not be captured.")
    }
}
