import XCTest
@testable import NokoCordCore

final class CallStateTests: XCTestCase {
    func testConnectionRequiresApprovedEncryptedTransport() {
        var state = CallState()
        XCTAssertEqual(state.beginConnection(approvedTransport: false, verifiedEncryption: true), .none)
        XCTAssertEqual(state.status, .unavailable(reason: "An approved call transport is required."))

        XCTAssertEqual(state.beginConnection(approvedTransport: true, verifiedEncryption: false), .none)
        XCTAssertEqual(state.status, .unavailable(reason: "Verified call encryption is required."))
    }

    func testStaleCompletionCannotConnectNewSession() {
        var state = CallState()
        let first = UUID(), second = UUID()
        XCTAssertEqual(state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: first), .connect(sessionID: first))
        XCTAssertEqual(state.disconnect(), .disconnect(sessionID: first))
        XCTAssertEqual(state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: second), .connect(sessionID: second))

        XCTAssertEqual(state.connectionSucceeded(sessionID: first, approvedTransport: true, verifiedEncryption: true), .none)
        XCTAssertEqual(state.status, .connecting(sessionID: second))
        XCTAssertEqual(state.connectionSucceeded(sessionID: second, approvedTransport: true, verifiedEncryption: true), .none)
        XCTAssertEqual(state.status, .connected(sessionID: second))
    }

    func testDuplicateBeginDoesNotAbandonActiveSession() {
        var state = CallState()
        let first = UUID(), second = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: first)

        XCTAssertEqual(state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: second), .none)
        XCTAssertEqual(state.status, .connecting(sessionID: first))
    }

    func testEncryptionFailureRequestsTeardownAndClearsMediaIntentions() {
        var state = CallState()
        let session = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        _ = state.setDeafened(true)

        XCTAssertEqual(state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: false), .disconnect(sessionID: session))
        XCTAssertEqual(state.status, .failed(reason: "The call could not verify an approved encrypted transport."))
        XCTAssertTrue(state.participants.isEmpty)
        XCTAssertFalse(state.isMuted)
        XCTAssertFalse(state.isDeafened)
    }

    func testDuplicateCompletionAfterConnectedIsIgnored() {
        var state = CallState()
        let session = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        _ = state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true)
        XCTAssertEqual(state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true), .none)
        XCTAssertEqual(state.status, .connected(sessionID: session))
    }

    func testReconnectRejectsStaleCompletion() {
        var state = CallState()
        let session = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        _ = state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true)
        XCTAssertEqual(state.beginReconnect(sessionID: session), .reconnect(sessionID: session, attempt: 1))
        XCTAssertEqual(state.reconnectSucceeded(sessionID: UUID(), approvedTransport: true, verifiedEncryption: true), .none)
        XCTAssertEqual(state.status, .reconnecting(sessionID: session, attempt: 1))
    }

    func testParticipantsAreDeduplicatedAndBounded() {
        var state = CallState()
        let session = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        let participants = (0...CallState.maximumParticipants).map { index in
            CallParticipant(id: index == 1 ? "0" : "\(index)", displayName: "Member \(index)")
        }
        _ = state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true, participants: participants)
        XCTAssertEqual(state.participants.count, CallState.maximumParticipants)
        XCTAssertEqual(Set(state.participants.map(\.id)).count, CallState.maximumParticipants)
    }

    func testDeafeningRestoresMuteIntent() {
        var state = CallState()
        XCTAssertEqual(state.setMuted(false), .applyLocalMedia(muted: false, deafened: false))
        XCTAssertEqual(state.setDeafened(true), .applyLocalMedia(muted: true, deafened: true))
        XCTAssertEqual(state.setDeafened(false), .applyLocalMedia(muted: false, deafened: false))

        _ = state.setMuted(true)
        _ = state.setDeafened(true)
        _ = state.setDeafened(false)
        XCTAssertEqual(state.setMuted(true), .applyLocalMedia(muted: true, deafened: false))
    }

    func testUnmuteWhileDeafenedTakesEffectAfterUndeafen() {
        var state = CallState()
        _ = state.setMuted(true)
        _ = state.setDeafened(true)
        XCTAssertEqual(state.setMuted(false), .applyLocalMedia(muted: true, deafened: true))
        XCTAssertEqual(state.setDeafened(false), .applyLocalMedia(muted: false, deafened: false))
    }

    func testDisconnectClearsParticipantsAndMediaIntentions() {
        var state = CallState()
        let session = UUID()
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        _ = state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true,
                                      participants: [CallParticipant(id: "one", displayName: "One")])
        _ = state.setDeafened(true)

        XCTAssertEqual(state.disconnect(), .disconnect(sessionID: session))
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(state.participants.isEmpty)
        XCTAssertFalse(state.isMuted)
        XCTAssertFalse(state.isDeafened)
    }

    func testParticipantUpdatesRequireCurrentConnectedSession() {
        var state = CallState()
        let session = UUID()
        let speaking = CallParticipant(id: "one", displayName: "One", isSpeaking: true)
        _ = state.beginConnection(approvedTransport: true, verifiedEncryption: true, sessionID: session)
        state.updateParticipants([speaking], sessionID: session)
        XCTAssertTrue(state.participants.isEmpty)
        _ = state.connectionSucceeded(sessionID: session, approvedTransport: true, verifiedEncryption: true)
        state.updateParticipants([speaking], sessionID: UUID())
        XCTAssertTrue(state.participants.isEmpty)
        state.updateParticipants([speaking], sessionID: session)
        XCTAssertEqual(state.participants, [speaking])
        _ = state.disconnect()
        state.updateParticipants([speaking], sessionID: session)
        XCTAssertTrue(state.participants.isEmpty)
    }
}
