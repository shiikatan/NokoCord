import XCTest
@testable import NokoCordCore

final class NotificationPolicyTests: XCTestCase {
    func testTupleHashingDoesNotMergeDistinctAccountEventPairs() {
        var policy = NotificationPolicy()
        let first = NotificationEvent(accountID: "a:b", eventID: "c", type: .mention)
        let second = NotificationEvent(accountID: "a", eventID: "b:c", type: .mention)
        guard case .deliver(let a) = policy.decide(first, context: .init()),
              case .deliver(let b) = policy.decide(second, context: .init()) else {
            return XCTFail("Distinct account/event pairs must both deliver")
        }
        XCTAssertNotEqual(a.requestID, b.requestID)
        XCTAssertNil(a.userInfo["conversation"])
    }

    private let event = NotificationEvent(accountID: "account-1", eventID: "event-1", type: .mention, conversationID: "conversation-1", actorName: "Ava", preview: "private preview")

    func testDefaultPolicyUsesGenericPrivacySafeBody() {
        var policy = NotificationPolicy()
        guard case .deliver(let plan) = policy.decide(event, context: .init()) else { return XCTFail("Expected delivery") }

        XCTAssertEqual(plan.body, "You have a new mention.")
        XCTAssertFalse(plan.body.contains("private preview"))
        XCTAssertEqual(plan.title, "You were mentioned")
        XCTAssertFalse(plan.title.contains("Ava"))
    }

    func testPreviewRequiresExplicitPreference() {
        var policy = NotificationPolicy(preferences: NotificationPreferences(enabled: Dictionary(uniqueKeysWithValues: NotificationEventType.allCases.map { ($0, true) }), showPreviews: true))

        guard case .deliver(let plan) = policy.decide(event, context: .init()) else { return XCTFail("Expected delivery") }
        XCTAssertEqual(plan.body, "private preview")
    }

    func testPreferencesAndContextSuppressDelivery() {
        var disabled = NotificationPreferences(); disabled.enabled[.mention] = false
        var policy = NotificationPolicy(preferences: disabled)
        XCTAssertEqual(policy.decide(event, context: .init()), .suppress)

        policy = NotificationPolicy()
        var active = NotificationSuppressionContext(appIsActive: true, activeConversationID: "conversation-1")
        XCTAssertEqual(policy.decide(event, context: active), .suppress)
        active = NotificationSuppressionContext(mutedConversationIDs: ["conversation-1"])
        XCTAssertEqual(policy.decide(event, context: active), .suppress)
        active = NotificationSuppressionContext(handledByOtherIntegration: true)
        XCTAssertEqual(policy.decide(event, context: active), .suppress)
    }

    func testDeduplicationIsAccountScopedAndBounded() {
        var policy = NotificationPolicy()
        XCTAssertNotEqual(policy.decide(event, context: .init()), .suppress)
        XCTAssertEqual(policy.decide(event, context: .init()), .suppress)

        for index in 0...NotificationPolicy.maxDedupEntries { _ = policy.decide(NotificationEvent(accountID: "account-1", eventID: "event-\(index)", type: .mention), context: .init()) }
        XCTAssertNotEqual(policy.decide(event, context: .init()), .suppress)
    }

    func testIDsAreHashedAndConversationGroupingIsStable() {
        var policy = NotificationPolicy()
        guard case .deliver(let first) = policy.decide(event, context: .init()) else { return XCTFail("Expected delivery") }
        XCTAssertEqual(first.requestID.count, 64)
        XCTAssertEqual(first.groupID.count, 64)
        XCTAssertFalse(first.requestID.contains("account-1"))
        XCTAssertFalse(first.userInfo.values.contains("conversation-1"))
    }

    func testLogoutClearsDeduplication() {
        var policy = NotificationPolicy()
        _ = policy.decide(event, context: .init())
        policy.clearDeduplication()
        XCTAssertNotEqual(policy.decide(event, context: .init()), .suppress)
    }
}
