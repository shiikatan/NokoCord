import Foundation

/// Validates the public implicit-grant callback without retaining its URL.
struct MLAuthorization: Sendable, CustomStringConvertible {
    let accessToken: String
    let lifetime: TimeInterval
    var description: String { "MLAuthorization(<redacted>)" }

    init(callback: URL, expectedState: String) throws {
        guard callback.scheme == "nokocord-maolist", callback.host == "oauth",
              callback.user == nil, callback.password == nil, callback.port == nil,
              callback.path.isEmpty || callback.path == "/",
              callback.query == nil, let fragment = callback.fragment,
              let items = URLComponents(string: "https://localhost/?" + fragment)?.queryItems else {
            throw MLError.authentication
        }
        var parameters: [String: String] = [:]
        for item in items {
            guard parameters[item.name] == nil, let value = item.value else { throw MLError.authentication }
            parameters[item.name] = value
        }
        guard !expectedState.isEmpty, parameters["state"] == expectedState,
              parameters["error"] == nil,
              let token = parameters["access_token"], !token.isEmpty,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              token.rangeOfCharacter(from: .controlCharacters) == nil,
              parameters["token_type"]?.lowercased() == "bearer" else { throw MLError.authentication }
        let seconds = parameters["expires_in"].flatMap(Double.init) ?? (parameters["expires_in"] == nil ? 31_536_000 : 0)
        guard seconds.isFinite, seconds > 0 else { throw MLError.authentication }
        accessToken = token
        lifetime = min(seconds, 31_536_000)
    }
}
