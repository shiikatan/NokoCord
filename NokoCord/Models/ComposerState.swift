import Foundation

enum ComposerAvailability: Equatable, Sendable {
    case unavailable(reason: String)
    case readOnly(reason: String)
    case ready

    var isReady: Bool { self == .ready }
    var reason: String? {
        switch self { case .unavailable(let reason), .readOnly(let reason): reason; case .ready: nil }
    }
}

enum ComposerSendState: Equatable, Sendable {
    case idle
    case sending
    case failed(reason: String)
}

enum ComposerValidationError: Error, Equatable, Sendable {
    case unavailable
    case busy
    case blank
    case tooLong(limit: Int)
}

struct ComposerState: Equatable, Sendable {
    var availability: ComposerAvailability = .unavailable(reason: String(localized: "Messaging is not available for this connection."))
    var sendState: ComposerSendState = .idle

    func validate(_ text: String, maxCharacters: Int) -> Result<String, ComposerValidationError> {
        guard availability.isReady else { return .failure(.unavailable) }
        guard sendState != .sending else { return .failure(.busy) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.blank) }
        guard text.count <= maxCharacters else { return .failure(.tooLong(limit: maxCharacters)) }
        return .success(text)
    }

    mutating func beginSending(_ text: String, maxCharacters: Int) -> Result<String, ComposerValidationError> {
        switch validate(text, maxCharacters: maxCharacters) {
        case .success(let value): sendState = .sending; return .success(value)
        case .failure(let error): return .failure(error)
        }
    }

    mutating func finish(_ result: Result<Void, Error>) {
        switch result {
        case .success: sendState = .idle
        case .failure(let error):
            if error is CancellationError { sendState = .idle }
            else { sendState = .failed(reason: error.localizedDescription) }
        }
    }

    static func draftAfterSuccessfulSend(submittedText: String, currentText: String) -> String {
        currentText == submittedText ? "" : currentText
    }
}
