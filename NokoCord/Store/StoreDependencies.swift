import Foundation

@MainActor protocol SessionAuthenticating: AnyObject {
    func signIn(origin: URL) async throws -> OAuthCredentials
    func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials
    func revoke(_ credentials: OAuthCredentials) async throws
    func cancel()
}
extension Authentication: SessionAuthenticating {}

protocol CredentialPersisting {
    func load() throws -> OAuthCredentials?
    func save(_ credentials: OAuthCredentials) throws
    func delete() throws
}
extension CredentialStore: CredentialPersisting {}

protocol AccountFetching: Sendable {
    func account(token: String) async throws -> DiscordUser
    func guilds(token: String) async throws -> [DiscordGuild]
}
extension DiscordREST: AccountFetching {}

protocol AccountCaching: Sendable {
    func load() async throws -> AccountSnapshot?
    func save(account: DiscordUser, guilds: [DiscordGuild]) async throws
    func clear() async throws
}
extension AccountCache: AccountCaching {}
