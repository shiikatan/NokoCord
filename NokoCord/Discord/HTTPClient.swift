import Foundation

// Redirects must not forward credentials to a different origin or an HTTP URL.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum TransportError: LocalizedError, Equatable {
    case invalidConfiguration, invalidResponse, responseTooLarge, unauthorized, denied
    case rateLimited(TimeInterval), serviceUnavailable, invalidCallback, cancelled, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "Configure a valid HTTPS authentication service origin in Settings.")
        case .invalidResponse: String(localized: "The service returned an unexpected response.")
        case .responseTooLarge: String(localized: "The response exceeded the safe size limit.")
        case .unauthorized: String(localized: "Your authorization expired or was revoked. Sign in again.")
        case .denied: String(localized: "This account has not granted the required access.")
        case .rateLimited(let seconds): String(localized: "Rate limited. Try again in \(Int(seconds.rounded(.up))) seconds.")
        case .serviceUnavailable: String(localized: "The service is unavailable. Try again later.")
        case .invalidCallback: String(localized: "The sign-in callback could not be verified. Please retry.")
        case .cancelled: String(localized: "Sign-in cancelled.")
        case .keychain: String(localized: "The secure credential store is unavailable.")
        }
    }
}

actor HTTPClient {
    private let session: URLSession
    private var cooldowns: [String: Date] = [:]
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func request(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw TransportError.invalidConfiguration }
        cooldowns = cooldowns.filter { $0.value > Date() }
        if let deadline = cooldowns[host], deadline > Date() { throw TransportError.rateLimited(deadline.timeIntervalSinceNow) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
        guard response.expectedContentLength <= 2_097_152 else { throw TransportError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 2_097_152 else { throw TransportError.responseTooLarge }
            body.append(byte)
        }
        switch response.statusCode {
        case 200..<300: return body
        case 401: throw TransportError.unauthorized
        case 403: throw TransportError.denied
        case 429:
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let raw = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (payload?["retry_after"] as? Double) ?? 60
            let delay = raw.isFinite ? max(1, min(raw, 86400)) : 60
            if cooldowns.count >= 128, cooldowns[host] == nil,
               let earliest = cooldowns.min(by: { $0.value < $1.value })?.key {
                cooldowns.removeValue(forKey: earliest)
            }
            cooldowns[host] = Date().addingTimeInterval(delay)
            throw TransportError.rateLimited(delay)
        case 500...599: throw TransportError.serviceUnavailable
        default: throw TransportError.invalidResponse
        }
    }
}
