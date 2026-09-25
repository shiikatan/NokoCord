import CryptoKit
import Foundation

enum NotificationEventType: String, CaseIterable, Codable, Sendable {
    case directMessage, mention, reply, thread, incomingCall, friendRequest
}

struct NotificationPreferences: Equatable, Codable, Sendable {
    var enabled: [NotificationEventType: Bool] = Dictionary(uniqueKeysWithValues: NotificationEventType.allCases.map { ($0, true) })
    var showPreviews = false
}

struct NotificationEvent: Equatable, Sendable {
    let accountID: String
    let eventID: String
    let type: NotificationEventType
    let conversationID: String?
    let actorName: String?
    let preview: String?
    init(accountID: String, eventID: String, type: NotificationEventType, conversationID: String? = nil, actorName: String? = nil, preview: String? = nil) {
        self.accountID = accountID; self.eventID = eventID; self.type = type; self.conversationID = conversationID; self.actorName = actorName; self.preview = preview
    }
}

struct NotificationSuppressionContext: Equatable, Sendable {
    var appIsActive = false
    var activeConversationID: String?
    var mutedConversationIDs: Set<String> = []
    var handledByOtherIntegration = false
}

struct PlannedNotification: Equatable, Sendable {
    let requestID: String
    let groupID: String
    let title: String
    let body: String
    let userInfo: [String: String]
}

enum NotificationDecision: Equatable, Sendable {
    case suppress
    case deliver(PlannedNotification)
}

struct NotificationPolicy: Sendable {
    static let maxDedupEntries = 512
    var preferences: NotificationPreferences
    private var deliveredKeys: [String] = []

    init(preferences: NotificationPreferences = .init()) { self.preferences = preferences }

    mutating func decide(_ event: NotificationEvent, context: NotificationSuppressionContext) -> NotificationDecision {
        guard !event.accountID.isEmpty, !event.eventID.isEmpty, event.accountID.utf8.count <= 128, event.eventID.utf8.count <= 128,
              (event.conversationID == nil || (!event.conversationID!.isEmpty && event.conversationID!.utf8.count <= 128)),
              (event.actorName == nil || event.actorName!.utf8.count <= 128), (event.preview == nil || event.preview!.utf8.count <= 2048) else { return .suppress }
        guard preferences.enabled[event.type, default: true], !context.handledByOtherIntegration else { return .suppress }
        if let conversationID = event.conversationID {
            guard !context.mutedConversationIDs.contains(conversationID), !(context.appIsActive && context.activeConversationID == conversationID) else { return .suppress }
        }
        let key = Self.scopedHash("event", event.accountID, event.eventID)
        guard !deliveredKeys.contains(key) else { return .suppress }
        deliveredKeys.append(key)
        if deliveredKeys.count > Self.maxDedupEntries { deliveredKeys.removeFirst(deliveredKeys.count - Self.maxDedupEntries) }
        let actor = preferences.showPreviews ? event.actorName?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let title = actor.flatMap { $0.isEmpty ? nil : $0 } ?? event.type.title
        let body = preferences.showPreviews ? (event.preview?.isEmpty == false ? event.preview! : event.type.defaultBody) : event.type.defaultBody
        let group = Self.scopedHash("conversation", event.accountID, event.conversationID ?? event.eventID)
        var info = ["account": Self.scopedHash(event.accountID), "type": event.type.rawValue]
        if let conversationID = event.conversationID { info["conversation"] = Self.scopedHash(conversationID) }
        return .deliver(PlannedNotification(requestID: key, groupID: group, title: title, body: body, userInfo: info))
    }

    mutating func rollback(_ event: NotificationEvent) { deliveredKeys.removeAll { $0 == Self.scopedHash("event", event.accountID, event.eventID) } }

    mutating func clearDeduplication() { deliveredKeys.removeAll(keepingCapacity: true) }

    static func scopedHash(_ values: String...) -> String { let data = values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|"); return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined() }
}

private extension NotificationEventType {
    var title: String {
        switch self { case .directMessage: String(localized: "New message"); case .mention: String(localized: "You were mentioned"); case .reply: String(localized: "New reply"); case .thread: String(localized: "Thread activity"); case .incomingCall: String(localized: "Incoming call"); case .friendRequest: String(localized: "Friend request") }
    }
    var defaultBody: String {
        switch self { case .directMessage: String(localized: "You have a new message."); case .mention: String(localized: "You have a new mention."); case .reply: String(localized: "You have a new reply."); case .thread: String(localized: "A thread has new activity."); case .incomingCall: String(localized: "You have an incoming call."); case .friendRequest: String(localized: "You have a new friend request.") }
    }
}
