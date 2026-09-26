import Foundation
import UserNotifications

protocol NotificationCenterClient: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removeAllPendingRequests()
    func removeAllDeliveredNotifications()
    func removeRequests(identifiers: [String])
}

final class NativeNotificationCenterClient: NotificationCenterClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
    func removeAllPendingRequests() { center.removeAllPendingNotificationRequests() }
    func removeAllDeliveredNotifications() { center.removeAllDeliveredNotifications() }
    func removeRequests(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

struct NotificationNavigation: Equatable, Sendable {
    let accountHash: String
    let conversationHash: String?
    let eventType: NotificationEventType
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let center: NotificationCenterClient
    private(set) var policy: NotificationPolicy
    private var generation = UUID()
    private var webNotificationTimestamps: [Date] = []
    var onNavigate: ((NotificationNavigation) -> Void)?

    init(center: NotificationCenterClient = NativeNotificationCenterClient(), preferences: NotificationPreferences = .init()) {
        self.center = center; policy = NotificationPolicy(preferences: preferences)
        super.init()
        (center as? NativeNotificationCenterClient)?.setDelegate(self)
    }

    /// Permission is requested only when the product explicitly invokes this method.
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.authorizationStatus() }

    func updatePreferences(_ preferences: NotificationPreferences) { policy.preferences = preferences }

    func deliver(_ event: NotificationEvent, context: NotificationSuppressionContext) async throws -> NotificationDecision {
        let operationGeneration = generation
        try Task.checkCancellation()
        let decision = policy.decide(event, context: context)
        guard case .deliver(let plan) = decision else { return decision }
        let content = UNMutableNotificationContent(); content.title = plan.title; content.body = plan.body; content.sound = .default; content.threadIdentifier = plan.groupID; content.userInfo = plan.userInfo
        let requestID = plan.requestID + "." + operationGeneration.uuidString
        do { try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil)) }
        catch {
            if generation == operationGeneration { policy.rollback(event) }
            throw error
        }
        guard generation == operationGeneration, !Task.isCancelled else {
            center.removeRequests(identifiers: [requestID])
            if generation == operationGeneration { policy.rollback(event) }
            return .suppress
        }
        return decision
    }

    func deliverWebNotification(title: String, body: String) async {
        let now = Date()
        webNotificationTimestamps = webNotificationTimestamps.filter { now.timeIntervalSince($0) < 5.0 }
        guard webNotificationTimestamps.count < 5 else { return }
        webNotificationTimestamps.append(now)

        if await center.authorizationStatus() == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let cleanTitle = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(128))
        let cleanBody = String(body.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(512))
        guard !cleanTitle.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = cleanTitle
        content.body = cleanBody
        content.sound = .default
        let requestID = "web-notif-" + UUID().uuidString
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        try? await center.add(request)
    }

    func clearOnLogout() {
        generation = UUID()
        webNotificationTimestamps.removeAll()
        center.removeAllPendingRequests(); center.removeAllDeliveredNotifications(); policy.clearDeduplication()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let navigation = Self.validatedNavigation(info)
        Task { @MainActor [weak self] in
            if let navigation { self?.onNavigate?(navigation) }
            completionHandler()
        }
    }

    nonisolated private static func validatedNavigation(_ info: [AnyHashable: Any]) -> NotificationNavigation? {
        guard let account = info["account"] as? String, isHash(account),
              let rawType = info["type"] as? String, let type = NotificationEventType(rawValue: rawType) else { return nil }
        let conversation = info["conversation"] as? String
        guard conversation == nil || isHash(conversation!) else { return nil }
        return NotificationNavigation(accountHash: account, conversationHash: conversation, eventType: type)
    }
    nonisolated private static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
}

private extension NativeNotificationCenterClient {
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { center.delegate = delegate }
}
