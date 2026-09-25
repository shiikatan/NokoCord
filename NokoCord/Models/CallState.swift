import Foundation

struct CallParticipant: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    var isSpeaking: Bool = false
}

enum CallStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case idle
    case connecting(sessionID: UUID)
    case connected(sessionID: UUID)
    case reconnecting(sessionID: UUID, attempt: Int)
    case failed(reason: String)
}

enum CallEffect: Equatable, Sendable {
    case none
    case connect(sessionID: UUID)
    case reconnect(sessionID: UUID, attempt: Int)
    case disconnect(sessionID: UUID)
    case applyLocalMedia(muted: Bool, deafened: Bool)
}

struct CallState: Equatable, Sendable {
    static let maximumParticipants = 256
    static let maximumParticipantIDBytes = 128
    static let maximumParticipantNameBytes = 256

    private(set) var status: CallStatus = .idle
    private(set) var participants: [CallParticipant] = []
    private(set) var isMuted = false
    private(set) var isDeafened = false
    private var muteBeforeDeafen: Bool?

    var sessionID: UUID? {
        switch status {
        case .connecting(let id), .connected(let id), .reconnecting(let id, _): id
        case .unavailable, .idle, .failed: nil
        }
    }

    @discardableResult
    mutating func beginConnection(approvedTransport: Bool, verifiedEncryption: Bool, sessionID: UUID = UUID()) -> CallEffect {
        switch status {
        case .connecting, .connected, .reconnecting:
            return .none
        case .unavailable, .idle, .failed:
            break
        }
        guard approvedTransport else {
            status = .unavailable(reason: String(localized: "An approved call transport is required."))
            return .none
        }
        guard verifiedEncryption else {
            status = .unavailable(reason: String(localized: "Verified call encryption is required."))
            return .none
        }
        participants.removeAll()
        status = .connecting(sessionID: sessionID)
        return .connect(sessionID: sessionID)
    }

    @discardableResult
    mutating func connectionSucceeded(sessionID: UUID, approvedTransport: Bool, verifiedEncryption: Bool,
                                      participants: [CallParticipant] = []) -> CallEffect {
        guard isCurrent(sessionID), isConnecting else { return .none }
        guard approvedTransport, verifiedEncryption else {
            let effect = CallEffect.disconnect(sessionID: sessionID)
            status = .failed(reason: String(localized: "The call could not verify an approved encrypted transport."))
            self.participants.removeAll()
            resetMediaIntentions()
            return effect
        }
        self.participants = bounded(participants)
        status = .connected(sessionID: sessionID)
        return .none
    }

    @discardableResult
    mutating func beginReconnect(sessionID: UUID) -> CallEffect {
        guard isCurrent(sessionID), case .connected = status else { return .none }
        let attempt = 1
        status = .reconnecting(sessionID: sessionID, attempt: attempt)
        return .reconnect(sessionID: sessionID, attempt: attempt)
    }

    @discardableResult
    mutating func reconnectSucceeded(sessionID: UUID, approvedTransport: Bool, verifiedEncryption: Bool,
                                     participants: [CallParticipant] = []) -> CallEffect {
        connectionSucceeded(sessionID: sessionID, approvedTransport: approvedTransport,
                            verifiedEncryption: verifiedEncryption, participants: participants)
    }

    mutating func updateParticipants(_ participants: [CallParticipant], sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        switch status {
        case .connected, .reconnecting: self.participants = bounded(participants)
        default: break
        }
    }

    @discardableResult
    mutating func setMuted(_ muted: Bool) -> CallEffect {
        if isDeafened {
            muteBeforeDeafen = muted
            isMuted = true
            return .applyLocalMedia(muted: true, deafened: true)
        }
        isMuted = muted
        return .applyLocalMedia(muted: isMuted, deafened: isDeafened)
    }

    @discardableResult
    mutating func setDeafened(_ deafened: Bool) -> CallEffect {
        if deafened && !isDeafened {
            muteBeforeDeafen = isMuted
            isMuted = true
        } else if !deafened && isDeafened {
            isMuted = muteBeforeDeafen ?? isMuted
            muteBeforeDeafen = nil
        }
        isDeafened = deafened
        return .applyLocalMedia(muted: isMuted, deafened: isDeafened)
    }

    @discardableResult
    mutating func disconnect() -> CallEffect {
        let effect = sessionID.map(CallEffect.disconnect) ?? .none
        status = .idle
        participants.removeAll()
        isMuted = false
        isDeafened = false
        muteBeforeDeafen = nil
        return effect
    }

    private func isCurrent(_ id: UUID) -> Bool { sessionID == id }
    private func bounded(_ values: [CallParticipant]) -> [CallParticipant] {
        var seen = Set<String>()
        var result: [CallParticipant] = []
        for participant in values.prefix(Self.maximumParticipants * 4) {
            if result.count == Self.maximumParticipants { break }
            guard !participant.id.isEmpty,
                  participant.id.utf8.count <= Self.maximumParticipantIDBytes,
                  participant.displayName.utf8.count <= Self.maximumParticipantNameBytes,
                  seen.insert(participant.id).inserted else { continue }
            result.append(participant)
        }
        return result
    }

    private var isConnecting: Bool {
        if case .connecting = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    private mutating func resetMediaIntentions() {
        isMuted = false
        isDeafened = false
        muteBeforeDeafen = nil
    }
}
