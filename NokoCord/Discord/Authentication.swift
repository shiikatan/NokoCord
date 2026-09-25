import AppKit
import AuthenticationServices
import CryptoKit
import Security

struct OAuthCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let brokerOrigin: String
    var accountID: String? = nil
}

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
    let token_type: String
    let scope: String
    private func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
    func credentials(origin: String) throws -> OAuthCredentials {
        guard token_type.lowercased() == "bearer", validSecret(access_token),
              validSecret(refresh_token), expires_in.isFinite, expires_in > 0,
              Set(scope.split(separator: " ")) == ["identify", "guilds"] else { throw TransportError.invalidResponse }
        return .init(accessToken: access_token, refreshToken: refresh_token,
                     expiresAt: Date().addingTimeInterval(min(expires_in, 31_536_000)), brokerOrigin: origin)
    }
}

enum BrokerConfiguration {
    static func origin(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/",
              let url = components.url else { throw TransportError.invalidConfiguration }
        return url
    }
}

enum SecureRandom {
    static func string() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TransportError.invalidCallback }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

@MainActor
final class Authentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var sessionID = UUID()
    private var continuation: CheckedContinuation<URL, Error>?
    private let http: HTTPClient
    init(http: HTTPClient) { self.http = http }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
    func signIn(origin: URL) async throws -> OAuthCredentials {
        guard session == nil else { throw TransportError.invalidCallback }
        let state = try SecureRandom.string(), verifier = try SecureRandom.string()
        let operationID = UUID()
        sessionID = operationID
        var components = URLComponents(url: origin.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "state", value: state), .init(name: "code_challenge", value: SecureRandom.challenge(verifier))]
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "nokocord") { [weak self] url, error in
                    Task { @MainActor in
                        guard let self, self.sessionID == operationID else { return }
                        if let url { self.finish(.success(url)) }
                        else { self.finish(.failure(TransportError.cancelled)) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(.failure(TransportError.invalidCallback)) }
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, self.sessionID == operationID else { return }
            self.cancel()
        } }
        try Task.checkCancellation()
        guard callback.scheme == "nokocord", callback.host == "oauth", callback.path == "/callback",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw TransportError.invalidCallback }
        let data = try await post(origin: origin, path: "exchange", payload: ["code": code, "code_verifier": verifier])
        return try JSONDecoder().decode(TokenResponse.self, from: data).credentials(origin: origin.absoluteString)
    }
    func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        let origin = try BrokerConfiguration.origin(credentials.brokerOrigin)
        let data = try await post(origin: origin, path: "refresh", payload: ["refresh_token": credentials.refreshToken])
        var refreshed = try JSONDecoder().decode(TokenResponse.self, from: data).credentials(origin: origin.absoluteString)
        // Refresh rotates credentials for the same grant. Preserve the cache
        // owner even if the subsequent account fetch fails or the app quits.
        refreshed.accountID = credentials.accountID
        return refreshed
    }
    func revoke(_ credentials: OAuthCredentials) async throws {
        _ = try await post(origin: BrokerConfiguration.origin(credentials.brokerOrigin), path: "revoke", payload: ["token": credentials.refreshToken])
    }
    private func post(origin: URL, path: String, payload: [String: String]) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return try await http.request(request)
    }
    func cancel() { sessionID = UUID(); session?.cancel(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}
