import Foundation
import UserNotifications
import XCTest
@testable import NokoCordCore

@MainActor
final class NotificationServiceTests: XCTestCase {
    func testInitializationAndDeliveryDoNotRequestAuthorization() async throws {
        let center = FakeNotificationCenter()
        let service = NotificationService(center: center)

        _ = try await service.deliver(event("auth"), context: .init())
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testLogoutRemovesNotificationWhenAnInFlightAddFinishesLate() async throws {
        let center = FakeNotificationCenter()
        center.gateAdds = true
        let service = NotificationService(center: center)
        let task = Task { try await service.deliver(event("late"), context: .init()) }

        await center.waitForAddStart()
        service.clearOnLogout()
        center.releaseAdd()
        let decision = try await task.value

        XCTAssertEqual(decision, .suppress)
        XCTAssertEqual(center.removedRequestIDs.count, 1)
        XCTAssertEqual(center.removedRequestIDs, center.addedRequestIDs)
    }

    func testFailedAddRollsBackDeduplicationSoRetryCanDeliver() async throws {
        let center = FakeNotificationCenter()
        center.failNextAdd = true
        let service = NotificationService(center: center)

        do { _ = try await service.deliver(event("retry"), context: .init()); XCTFail("Expected add failure") }
        catch { XCTAssertEqual(center.addCalls, 1) }

        let decision = try await service.deliver(event("retry"), context: .init())
        guard case .deliver = decision else { return XCTFail("Retry was suppressed after failed add") }
        XCTAssertEqual(center.addCalls, 2)
    }

    func testSettingsPersistPolicyAndClearPostedNotificationsWithoutRequestingPermission() async throws {
        let suite = "NokoCord.NotificationSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = NotificationPreferencesStore(defaults: defaults)
        let center = FakeNotificationCenter()
        let service = NotificationService(center: center)
        let settings = NotificationSettings(persistence: persistence, service: service)
        await settings.refreshAuthorization()
        XCTAssertEqual(center.authorizationRequests, 0)
        settings.setEnabled(false, for: .mention)
        settings.setPreviews(true)
        XCTAssertEqual(persistence.load(), settings.preferences)
        XCTAssertEqual(service.policy.preferences, settings.preferences)
        XCTAssertEqual(center.pendingClears, 2)
        XCTAssertEqual(center.deliveredClears, 2)
        let decision = try await service.deliver(event("disabled"), context: .init())
        XCTAssertEqual(decision, .suppress)
        await settings.requestAuthorization()
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(settings.authorization, .authorized)
    }

    private func event(_ id: String) -> NotificationEvent {
        NotificationEvent(accountID: "account", eventID: id, type: .mention, conversationID: "conversation")
    }
}

private final class FakeNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus { authorizationRequests > 0 ? .authorized : .notDetermined }
    var pendingClears = 0
    var deliveredClears = 0
    private let lock = NSLock()
    private var addStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var addContinuation: CheckedContinuation<Void, Never>?
    var gateAdds = false
    var failNextAdd = false
    var authorizationRequests = 0
    var addCalls = 0
    var addedRequestIDs: [String] = []
    var removedRequestIDs: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { authorizationRequests += 1 }; return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        let (shouldFail, gated) = lock.withLock {
            addCalls += 1; addedRequestIDs.append(request.identifier)
            let fail = failNextAdd; failNextAdd = false
            return (fail, gateAdds)
        }
        if shouldFail { throw TestNotificationError.failed }
        if gated {
            await withCheckedContinuation { continuation in
                let waiters = lock.withLock {
                    addContinuation = continuation; addStarted = true
                    let waiting = startWaiters; startWaiters.removeAll(); return waiting
                }
                waiters.forEach { $0.resume() }
            }
        }
    }

    func removeAllPendingRequests() { pendingClears += 1 }
    func removeAllDeliveredNotifications() { deliveredClears += 1 }
    func removeRequests(identifiers: [String]) { lock.lock(); removedRequestIDs.append(contentsOf: identifiers); lock.unlock() }

    func waitForAddStart() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                if addStarted { return true }
                startWaiters.append(continuation); return false
            }
            if started { continuation.resume() }
        }
    }

    func releaseAdd() { lock.lock(); let continuation = addContinuation; addContinuation = nil; lock.unlock(); continuation?.resume() }
}

private enum TestNotificationError: Error { case failed }
