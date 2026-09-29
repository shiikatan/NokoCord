import XCTest
@testable import NokoCordCore

final class NokoActivityBridgeTests: XCTestCase {
    func testFailedPublishPreservesDesiredActivityAndIdenticalRequestRetries() async throws {
        let transport = RecordingActivityTransport(failNextUpdates: 1)
        let bridge = NokoActivityBridge(transport: transport)
        let owner = NokoActivityOwner("apple-music")
        let activity = NokoActivity(title: "Blue", details: "Album", state: "Playing")

        do {
            _ = try await bridge.publish(activity, ownedBy: owner)
            XCTFail("Expected the first transport update to fail")
        } catch {
            // Expected: a failed transport call must remain retryable.
        }

        let failedSnapshot = await bridge.snapshot()
        XCTAssertEqual(failedSnapshot.owner, owner)
        XCTAssertEqual(failedSnapshot.desiredActivity, activity)
        XCTAssertNil(failedSnapshot.lastPublishedActivity)

        let retried = try await bridge.publish(activity, ownedBy: owner)
        XCTAssertEqual(retried, .published)
        let deduplicated = try await bridge.publish(activity, ownedBy: owner)
        XCTAssertEqual(deduplicated, .unchanged)

        let events = await transport.events
        XCTAssertEqual(events, [.update(activity), .update(activity)])
        let finalSnapshot = await bridge.snapshot()
        XCTAssertEqual(finalSnapshot.lastPublishedActivity, activity)
    }

    func testProviderSwitchClearsOldActivityAndStaleStopDoesNotClearNewOwner() async throws {
        let transport = RecordingActivityTransport()
        let bridge = NokoActivityBridge(transport: transport)
        let music = NokoActivityOwner("apple-music")
        let debug = NokoActivityOwner("debug-smoke")
        let first = NokoActivity(title: "First")
        let second = NokoActivity(title: "Second")

        _ = try await bridge.publish(first, ownedBy: music)
        _ = try await bridge.publish(second, ownedBy: debug)
        let staleStop = try await bridge.stop(ownedBy: music)
        XCTAssertEqual(staleStop, .alreadyStopped)
        let stop = try await bridge.stop(ownedBy: debug)
        XCTAssertEqual(stop, .cleared)

        let events = await transport.events
        XCTAssertEqual(events, [
            .update(first),
            .clear,
            .update(second),
            .clear
        ])
        let snapshot = await bridge.snapshot()
        XCTAssertNil(snapshot.owner)
        XCTAssertNil(snapshot.desiredActivity)
        XCTAssertNil(snapshot.lastPublishedActivity)
        XCTAssertFalse(snapshot.clearRequired)
    }

    func testReassertForcesCurrentActivityWithoutDroppingOwnerAndGuardsInflightGeneration() async throws {
        let transport = SuspendedActivityTransport()
        let bridge = NokoActivityBridge(transport: transport)
        let owner = NokoActivityOwner("apple-music")
        let activity = NokoActivity(title: "Current", details: "Album", state: "Playing")

        let initialRequest = Task { try await bridge.publish(activity, ownedBy: owner) }
        await transport.waitForBlockedUpdate()
        let initialGeneration = await bridge.snapshot().generation

        let reassertRequest = Task { try await bridge.reassert() }
        for _ in 0..<100 {
            if await bridge.snapshot().generation > initialGeneration { break }
            await Task.yield()
        }
        let pendingSnapshot = await bridge.snapshot()
        XCTAssertEqual(pendingSnapshot.owner, owner)
        XCTAssertEqual(pendingSnapshot.desiredActivity, activity)
        XCTAssertGreaterThan(pendingSnapshot.generation, initialGeneration)

        await transport.releaseBlockedUpdate()
        let initialResult = try await initialRequest.value
        let reassertResult = try await reassertRequest.value
        XCTAssertEqual(initialResult, .superseded)
        XCTAssertEqual(reassertResult, .published)

        // A later reassert must publish again even though the activity matches
        // the last successful value.
        let repeatedReassert = try await bridge.reassert()
        XCTAssertEqual(repeatedReassert, .published)
        let events = await transport.events
        XCTAssertEqual(events, [.update(activity), .update(activity), .update(activity)])

        let maximumConcurrentUpdates = await transport.maximumConcurrentUpdates
        XCTAssertEqual(maximumConcurrentUpdates, 1)
        let finalSnapshot = await bridge.snapshot()
        XCTAssertEqual(finalSnapshot.owner, owner)
        XCTAssertEqual(finalSnapshot.desiredActivity, activity)
        XCTAssertEqual(finalSnapshot.lastPublishedOwner, owner)
        XCTAssertEqual(finalSnapshot.lastPublishedActivity, activity)
    }

    func testStaleSuccessfulPublishInvalidatesCacheBeforeLatestFailureAndRetry() async throws {
        let transport = ControlledActivityTransport()
        let bridge = NokoActivityBridge(transport: transport)
        let owner = NokoActivityOwner("apple-music")
        let activityA = NokoActivity(title: "A")
        let activityB = NokoActivity(title: "B")

        _ = try await bridge.publish(activityA, ownedBy: owner)
        let initialGeneration = await bridge.snapshot().generation
        await transport.blockNextUpdate(title: activityB.title)
        await transport.failNextUpdate(title: activityA.title)

        let requestB = Task { try await bridge.publish(activityB, ownedBy: owner) }
        await transport.waitUntilBlockedUpdate()

        let latestRequestA = Task { try await bridge.publish(activityA, ownedBy: owner) }
        for _ in 0..<100 {
            if await bridge.snapshot().generation >= initialGeneration + 2 { break }
            await Task.yield()
        }
        let queuedSnapshot = await bridge.snapshot()
        XCTAssertEqual(queuedSnapshot.desiredActivity, activityA)
        XCTAssertGreaterThanOrEqual(queuedSnapshot.generation, initialGeneration + 2)

        await transport.releaseBlockedUpdate()
        let resultB = try await requestB.value
        XCTAssertEqual(resultB, .superseded)
        do {
            _ = try await latestRequestA.value
            XCTFail("Expected the latest activity A update to fail")
        } catch {
            // Expected: retry must remain necessary after stale B reached Discord.
        }

        let failedSnapshot = await bridge.snapshot()
        XCTAssertEqual(failedSnapshot.desiredActivity, activityA)
        XCTAssertNil(failedSnapshot.lastPublishedActivity)

        let retry = try await bridge.publish(activityA, ownedBy: owner)
        XCTAssertEqual(retry, .published)
        let events = await transport.events
        XCTAssertEqual(events, [
            .update(activityA.title),
            .update(activityB.title),
            .update(activityA.title),
            .update(activityA.title)
        ])
    }

    func testSupersededUpdateCannotCommitAndTransportCallsStaySerialized() async throws {
        let transport = SuspendedActivityTransport()
        let bridge = NokoActivityBridge(transport: transport)
        let owner = NokoActivityOwner("apple-music")
        let first = NokoActivity(title: "First")
        let second = NokoActivity(title: "Second")

        let firstRequest = Task { try await bridge.publish(first, ownedBy: owner) }
        await transport.waitForBlockedUpdate()

        let secondRequest = Task { try await bridge.publish(second, ownedBy: owner) }
        for _ in 0..<100 {
            if await bridge.snapshot().desiredActivity == second { break }
            await Task.yield()
        }
        let pendingSnapshot = await bridge.snapshot()
        XCTAssertEqual(pendingSnapshot.desiredActivity, second)

        await transport.releaseBlockedUpdate()
        let firstResult = try await firstRequest.value
        let secondResult = try await secondRequest.value
        XCTAssertEqual(firstResult, .superseded)
        XCTAssertEqual(secondResult, .published)

        let events = await transport.events
        XCTAssertEqual(events, [.update(first), .update(second)])
        let maximumConcurrentUpdates = await transport.maximumConcurrentUpdates
        XCTAssertEqual(maximumConcurrentUpdates, 1)
        let finalSnapshot = await bridge.snapshot()
        XCTAssertEqual(finalSnapshot.lastPublishedActivity, second)
    }
}

private actor RecordingActivityTransport: NokoActivityTransport {
    enum Event: Equatable {
        case update(NokoActivity)
        case clear
    }

    private(set) var events: [Event] = []
    private var failuresRemaining: Int

    init(failNextUpdates: Int = 0) {
        failuresRemaining = failNextUpdates
    }

    func update(activity: NokoActivity) async throws {
        events.append(.update(activity))
        guard failuresRemaining > 0 else { return }
        failuresRemaining -= 1
        throw RecordingError.expectedFailure
    }

    func clear() async throws {
        events.append(.clear)
    }

    private enum RecordingError: Error {
        case expectedFailure
    }
}

private actor SuspendedActivityTransport: NokoActivityTransport {
    enum Event: Equatable {
        case update(NokoActivity)
        case clear
    }

    private(set) var events: [Event] = []
    private(set) var maximumConcurrentUpdates = 0
    private var activeUpdates = 0
    private var hasBlockedFirstUpdate = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func update(activity: NokoActivity) async throws {
        events.append(.update(activity))
        activeUpdates += 1
        maximumConcurrentUpdates = max(maximumConcurrentUpdates, activeUpdates)

        if !hasBlockedFirstUpdate {
            hasBlockedFirstUpdate = true
            startContinuation?.resume()
            startContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        activeUpdates -= 1
    }

    func clear() async throws {
        events.append(.clear)
    }

    func waitForBlockedUpdate() async {
        guard !hasBlockedFirstUpdate else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseBlockedUpdate() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ControlledActivityTransport: NokoActivityTransport {
    enum Event: Equatable {
        case update(String)
        case clear
    }

    private(set) var events: [Event] = []
    private var blockedTitle: String?
    private var blockedUpdateStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var failuresRemainingByTitle: [String: Int] = [:]

    func blockNextUpdate(title: String) {
        blockedTitle = title
        blockedUpdateStarted = false
    }

    func waitUntilBlockedUpdate() async {
        guard !blockedUpdateStarted else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseBlockedUpdate() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func failNextUpdate(title: String) {
        failuresRemainingByTitle[title, default: 0] += 1
    }

    func update(activity: NokoActivity) async throws {
        events.append(.update(activity.title))
        if blockedTitle == activity.title {
            blockedUpdateStarted = true
            blockedTitle = nil
            startContinuation?.resume()
            startContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if let failuresRemaining = failuresRemainingByTitle[activity.title], failuresRemaining > 0 {
            failuresRemainingByTitle[activity.title] = failuresRemaining - 1
            throw ControlledError.expectedFailure
        }
    }

    func clear() async throws {
        events.append(.clear)
    }

    private enum ControlledError: Error {
        case expectedFailure
    }
}
