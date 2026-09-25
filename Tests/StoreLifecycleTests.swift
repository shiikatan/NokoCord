import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class StoreLifecycleTests: XCTestCase {
    private let credentials = OAuthCredentials(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Date().addingTimeInterval(3600),
        brokerOrigin: "https://auth.example.com",
        accountID: "user-1"
    )
    private let user = DiscordUser(id: "user-1", username: "Ava", globalName: nil, avatar: nil)
    private let guild = DiscordGuild(id: "guild-1", name: "Test Guild", icon: nil, owner: true, permissions: "0")

    func testDraftRetentionAcrossLogoutFailureAndInterruptionStaysAccountIsolated() async throws {
        for keychainFailure in [false, true] {
            for interrupt in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let drafts = DraftStore(directory: directory)
                try await drafts.save(Draft(text: "first account"), accountID: "user-1", conversationID: "conversation")
                try await drafts.save(Draft(text: "second account"), accountID: "user-2", conversationID: "conversation")
                let store = AppStore(authentication: FakeAuthentication(),
                                     keychain: FakeKeychain(credentials: credentials, deleteError: keychainFailure),
                                     cache: FakeCache(), rest: FakeREST(user: user, guilds: [guild]),
                                     monitorNetwork: false, draftStore: drafts)
                await store.restore(); await store.waitForCurrentOperation()
                store.signOut()
                if interrupt { store.cancelSignIn() }
                await store.waitForCurrentOperation()
                let first = try await drafts.load(accountID: "user-1", conversationID: "conversation")
                let second = try await drafts.load(accountID: "user-2", conversationID: "conversation")
                let unrelated = try await drafts.load(accountID: "user-3", conversationID: "conversation")
                XCTAssertEqual(first?.text, "first account")
                XCTAssertEqual(second?.text, "second account")
                XCTAssertNil(unrelated)
            }
        }
    }

    func testExplicitDraftDeletionClearsOnlyNativeDraftStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = DraftStore(directory: directory)
        try await drafts.save(Draft(text: "retained"), accountID: "user-1", conversationID: "conversation")
        let keychain = FakeKeychain(credentials: credentials)
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain,
                             cache: FakeCache(), rest: FakeREST(user: user), monitorNetwork: false, draftStore: drafts)
        await store.clearRetainedDrafts()
        let remaining = try await drafts.load(accountID: "user-1", conversationID: "conversation")
        XCTAssertNil(remaining)
        XCTAssertNotNil(store.draftCleanupMessage)
        XCTAssertEqual(try keychain.load()?.accountID, "user-1")
        XCTAssertEqual(keychain.deleteCallCount(), 0)
    }

    func testBrokerOriginPersistsAcrossLogoutButNeverStoresCredentialBearingInput() async throws {
        let suite = "NokoCord.BrokerPreferences.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("https://fixture:secret@auth.example.com/?token=fixture", forKey: "brokerURL")
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(),
                             cache: FakeCache(), rest: FakeREST(), monitorNetwork: false, preferences: preferences)
        XCTAssertEqual(store.brokerURL, "")
        XCTAssertNil(preferences.string(forKey: "brokerURL"))
        store.brokerURL = "https://auth.example.com"
        for invalid in ["https://fixture:secret@auth.example.com", "https://auth.example.com/?token=fixture", "https://auth.example.com/#fixture", "https://auth.example.com/private"] {
            store.brokerURL = invalid
            XCTAssertEqual(preferences.string(forKey: "brokerURL"), "https://auth.example.com")
        }
        store.brokerURL = "https://auth.example.com"
        store.signOut(); await store.waitForCurrentOperation()
        XCTAssertEqual(preferences.string(forKey: "brokerURL"), "https://auth.example.com")
        store.brokerURL = ""
        XCTAssertNil(preferences.string(forKey: "brokerURL"))
    }

    func testSessionInvalidationAndLogoutClearNotifications() async {
        var clears = 0
        let avatars = AvatarClearCounter()
        let rest = FakeREST(user: user, guilds: [guild])
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: FakeCache(), rest: rest, monitorNetwork: false,
                             clearNotifications: { clears += 1 }, clearAvatars: { await avatars.clear() })
        await store.restore()
        await store.waitForCurrentOperation()
        XCTAssertEqual(clears, 0)
        await rest.fail(with: .unauthorized)
        store.refresh()
        await store.waitForCurrentOperation()
        XCTAssertEqual(clears, 1)
        let invalidationClears = await avatars.count
        XCTAssertEqual(invalidationClears, 1)
        store.signOut()
        await store.waitForCurrentOperation()
        XCTAssertEqual(clears, 2)
        let logoutClears = await avatars.count
        XCTAssertEqual(logoutClears, 2)
    }

    func testNavigationRejectsUnknownGuildAndDropsRemovedDestinations() async {
        let second = DiscordGuild(id: "guild-2", name: "Second", icon: nil, owner: nil, permissions: nil)
        let rest = FakeREST(user: user, guilds: [guild, second])
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: FakeCache(), rest: rest, monitorNetwork: false)
        await store.restore()
        await store.waitForCurrentOperation()
        store.selectGuild("unknown")
        XCTAssertNil(store.selectedGuildID)
        XCTAssertFalse(store.canGoBack)
        store.selectGuild(guild.id)
        store.selectGuild(second.id)
        store.goBack()
        XCTAssertEqual(store.selectedGuildID, guild.id)
        await rest.replaceGuilds([second])
        store.refresh()
        await store.waitForCurrentOperation()
        XCTAssertNil(store.selectedGuildID)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)
        store.goForward()
        XCTAssertEqual(store.selectedGuildID, second.id)
        store.goBack()
        XCTAssertNil(store.selectedGuildID)
    }

    func testInvalidSessionClearsNavigationAndSearch() async {
        let rest = FakeREST(user: user, guilds: [guild])
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: FakeCache(), rest: rest, monitorNetwork: false)
        await store.restore()
        await store.waitForCurrentOperation()
        store.selectGuild(guild.id)
        store.searchText = "private server search"
        let presentationID = store.accountPresentationID
        await rest.fail(with: .unauthorized)
        store.refresh()
        await store.waitForCurrentOperation()
        XCTAssertEqual(store.state, .invalidSession)
        XCTAssertNil(store.selectedGuildID)
        XCTAssertFalse(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
        XCTAssertEqual(store.searchText, "")
        XCTAssertNotEqual(store.accountPresentationID, presentationID)
    }

    func testRestoreLoadsCachedIdentityAndGuildsThenRefreshesAccount() async {
        let keychain = FakeKeychain(credentials: credentials)
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = FakeCache(snapshot: AccountSnapshot(version: 1, account: user, guilds: [guild], savedAt: cachedAt))
        let rest = FakeREST(user: user, guilds: [guild])
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain, cache: cache, rest: rest, monitorNetwork: false)

        await store.restore()
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.user, user)
        XCTAssertEqual(store.guilds, [guild])
        XCTAssertEqual(store.state, .connected)
        XCTAssertNotNil(store.accountUpdatedAt)
        XCTAssertNotEqual(store.accountUpdatedAt, cachedAt)
        XCTAssertFalse(store.accountLoadedFromCache)
        XCTAssertTrue(store.networkIsAvailable)
        XCTAssertTrue(store.canRefresh)
        let accountCalls = await rest.accountCallCount()
        let guildCalls = await rest.guildsCallCount()
        XCTAssertEqual(accountCalls, 1)
        XCTAssertEqual(guildCalls, 1)
    }

    func testSignOutPreventsDelayedRestoreFromOverwritingNewState() async {
        let keychain = FakeKeychain(credentials: credentials)
        let cache = FakeCache(loadGate: true)
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain, cache: cache, rest: FakeREST(user: user, guilds: [guild]), monitorNetwork: false)

        let restoreTask = Task { await store.restore() }
        await cache.waitForLoadStart()
        store.signOut()
        await cache.resumeLoad(with: AccountSnapshot(version: 1, account: user, guilds: [guild], savedAt: Date()))
        await restoreTask.value
        await store.waitForCurrentOperation()

        XCTAssertNil(store.user)
        XCTAssertTrue(store.guilds.isEmpty)
        XCTAssertEqual(store.state, .signedOut)
    }

    func testClearCacheInvalidatesPendingRestoreLoad() async {
        let keychain = FakeKeychain(credentials: credentials)
        let cache = FakeCache(loadGate: true)
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain, cache: cache, rest: FakeREST(user: user, guilds: [guild]), monitorNetwork: false)

        let restoreTask = Task { await store.restore() }
        await cache.waitForLoadStart()
        await store.clearCache()
        await cache.resumeLoad(with: AccountSnapshot(version: 1, account: user, guilds: [guild], savedAt: Date()))
        await restoreTask.value

        XCTAssertNil(store.user)
        XCTAssertTrue(store.guilds.isEmpty)
        XCTAssertNotEqual(store.state, .connected)
    }

    func testSignOutReportsRemoteRevocationFailureAfterLocalCleanup() async {
        let auth = FakeAuthentication(revokeError: true)
        let keychain = FakeKeychain(credentials: credentials)
        let store = AppStore(authentication: auth, keychain: keychain, cache: FakeCache(), rest: FakeREST(user: user, guilds: [guild]), monitorNetwork: false)
        await store.restore()
        await store.waitForCurrentOperation()

        store.signOut()
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.state, .failed("Remote revocation failed. Remove NokoCord in Discord’s Authorized Apps settings. Local credentials and cached account data were removed unless a prior Keychain error was shown."))
        XCTAssertNil(store.accountUpdatedAt)
        XCTAssertFalse(store.accountLoadedFromCache)
        XCTAssertFalse(store.canRefresh)
        let revokes = auth.revokeCallCount()
        let deletes = keychain.deleteCallCount()
        XCTAssertEqual(revokes, 1)
        XCTAssertEqual(deletes, 1)
    }

    func testSignOutReportsKeychainCleanupFailure() async {
        let auth = FakeAuthentication()
        let keychain = FakeKeychain(credentials: credentials, deleteError: true)
        let store = AppStore(authentication: auth, keychain: keychain, cache: FakeCache(), rest: FakeREST(user: user, guilds: [guild]), monitorNetwork: false)
        await store.restore()
        await store.waitForCurrentOperation()

        store.signOut()
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.state, .failed("Keychain cleanup failed. Retry Disconnect Profile before quitting; saved credentials may remain on this Mac."))
        let revokes = auth.revokeCallCount()
        XCTAssertEqual(revokes, 1)
    }

    func testUnauthorizedAccountLoadClearsSessionAndReportsInvalidSession() async {
        let keychain = FakeKeychain(credentials: credentials)
        let rest = FakeREST(error: .unauthorized)
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain, cache: FakeCache(), rest: rest, monitorNetwork: false)

        await store.restore()
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.state, .invalidSession)
        XCTAssertNil(store.user)
        XCTAssertTrue(store.guilds.isEmpty)
        let deletes = keychain.deleteCallCount()
        XCTAssertEqual(deletes, 1)
    }

    func testCancelBeforeAccountArrivesDoesNotReportConnected() async {
        let keychain = FakeKeychain(credentials: credentials)
        let rest = FakeREST(user: user, guilds: [guild], accountGate: true)
        let store = AppStore(authentication: FakeAuthentication(), keychain: keychain, cache: FakeCache(), rest: rest, monitorNetwork: false)

        await store.restore()
        await rest.waitForAccountStart()
        store.cancelSignIn()
        await rest.resumeAccount()
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.state, .offline)
        XCTAssertNil(store.user)
        XCTAssertTrue(store.guilds.isEmpty)
    }

    func testOfflineTransitionRejectsLateResponseAndReconnectRefreshes() async {
        let rest = FakeREST(user: user, guilds: [guild], accountGate: true)
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: FakeCache(), rest: rest, monitorNetwork: false)
        await store.restore()
        await rest.waitForAccountStart()
        store.networkPathChanged(isAvailable: false)
        await rest.resumeAccount()
        await store.waitForCurrentOperation()
        XCTAssertEqual(store.state, .offline)
        XCTAssertNil(store.user)
        XCTAssertFalse(store.networkIsAvailable)
        XCTAssertFalse(store.canRefresh)

        store.refresh()
        let offlineCalls = await rest.accountCallCount()
        XCTAssertEqual(offlineCalls, 1)
        store.networkPathChanged(isAvailable: true)
        await store.waitForCurrentOperation()
        XCTAssertEqual(store.state, .connected)
        XCTAssertEqual(store.user, user)
        XCTAssertTrue(store.networkIsAvailable)
        XCTAssertNotNil(store.accountUpdatedAt)
        XCTAssertFalse(store.accountLoadedFromCache)
        XCTAssertTrue(store.canRefresh)
        let recoveredCalls = await rest.accountCallCount()
        XCTAssertEqual(recoveredCalls, 2)
    }

    func testFailedRefreshPreservesCachedAccountFreshness() async {
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let cache = FakeCache(snapshot: AccountSnapshot(version: 1, account: user, guilds: [guild], savedAt: cachedAt))
        let rest = FakeREST(error: .serviceUnavailable)
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: cache, rest: rest, monitorNetwork: false)

        store.networkPathChanged(isAvailable: false)
        await store.restore()
        await store.waitForCurrentOperation()
        XCTAssertEqual(store.accountUpdatedAt, cachedAt)
        XCTAssertTrue(store.accountLoadedFromCache)

        store.networkPathChanged(isAvailable: true)
        await store.waitForCurrentOperation()

        XCTAssertEqual(store.state, .failed("The service is unavailable. Try again later."))
        XCTAssertEqual(store.accountUpdatedAt, cachedAt)
        XCTAssertTrue(store.accountLoadedFromCache)
    }

    func testRestoreWhileOfflineKeepsCachedAccountWithoutNetworkRequests() async {
        let rest = FakeREST(user: user, guilds: [guild])
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let cache = FakeCache(snapshot: AccountSnapshot(version: 1, account: user, guilds: [guild], savedAt: cachedAt))
        let store = AppStore(authentication: FakeAuthentication(), keychain: FakeKeychain(credentials: credentials),
                             cache: cache, rest: rest, monitorNetwork: false)
        store.networkPathChanged(isAvailable: false)
        await store.restore()
        await store.waitForCurrentOperation()
        XCTAssertEqual(store.state, .offline)
        XCTAssertEqual(store.user, user)
        XCTAssertEqual(store.accountUpdatedAt, cachedAt)
        XCTAssertTrue(store.accountLoadedFromCache)
        XCTAssertFalse(store.networkIsAvailable)
        XCTAssertFalse(store.canRefresh)
        let calls = await rest.accountCallCount()
        XCTAssertEqual(calls, 0)
        await store.clearCache()
        XCTAssertEqual(store.state, .offline)
        store.cancelSignIn()
        XCTAssertEqual(store.state, .offline)
    }
}

private actor AvatarClearCounter {
    private(set) var count = 0
    func clear() { count += 1 }
}

private final class FakeKeychain: CredentialPersisting {
    private var value: OAuthCredentials?
    private let deleteError: Bool
    private var deletes = 0

    init(credentials: OAuthCredentials? = nil, deleteError: Bool = false) {
        value = credentials
        self.deleteError = deleteError
    }
    func load() throws -> OAuthCredentials? { value }
    func save(_ credentials: OAuthCredentials) throws { value = credentials }
    func delete() throws {
        deletes += 1
        if deleteError { throw TransportError.keychain(-1) }
        value = nil
    }
    func deleteCallCount() -> Int { deletes }
}

@MainActor
private final class FakeAuthentication: SessionAuthenticating {
    private let revokeError: Bool
    private var revokes = 0
    init(revokeError: Bool = false) { self.revokeError = revokeError }
    func signIn(origin: URL) async throws -> OAuthCredentials { XCTFail("Unexpected sign-in"); throw TransportError.invalidResponse }
    func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials { credentials }
    func revoke(_ credentials: OAuthCredentials) async throws {
        revokes += 1
        if revokeError { throw TransportError.serviceUnavailable }
    }
    func cancel() {}
    func revokeCallCount() -> Int { revokes }
}

private actor FakeCache: AccountCaching {
    private let snapshot: AccountSnapshot?
    private let loadGate: Bool
    private var loadStarted = false
    private var loadContinuation: CheckedContinuation<AccountSnapshot?, Never>?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    init(snapshot: AccountSnapshot? = nil, loadGate: Bool = false) {
        self.snapshot = snapshot
        self.loadGate = loadGate
    }
    func load() async throws -> AccountSnapshot? {
        loadStarted = true
        loadWaiters.forEach { $0.resume() }
        loadWaiters.removeAll()
        guard loadGate else { return snapshot }
        return await withCheckedContinuation { loadContinuation = $0 }
    }
    func save(account: DiscordUser, guilds: [DiscordGuild]) async throws {}
    func clear() async throws {}
    func waitForLoadStart() async {
        if !loadStarted { await withCheckedContinuation { loadWaiters.append($0) } }
    }
    func resumeLoad(with snapshot: AccountSnapshot?) {
        loadContinuation?.resume(returning: snapshot)
        loadContinuation = nil
    }
}

private actor FakeREST: AccountFetching {
    private let resultUser: DiscordUser?
    private var resultGuilds: [DiscordGuild]
    private var error: TransportError?
    private var accountGate: Bool
    private var accountStarted = false
    private var accountContinuation: CheckedContinuation<DiscordUser, Error>?
    private var accountWaiters: [CheckedContinuation<Void, Never>] = []
    private var accountCalls = 0
    private var guildCalls = 0

    init(user: DiscordUser? = nil, guilds: [DiscordGuild] = [], error: TransportError? = nil, accountGate: Bool = false) {
        resultUser = user
        resultGuilds = guilds
        self.error = error
        self.accountGate = accountGate
    }
    func account(token: String) async throws -> DiscordUser {
        accountCalls += 1
        if let error { throw error }
        guard let resultUser else { throw TransportError.invalidResponse }
        if accountGate {
            accountStarted = true
            accountWaiters.forEach { $0.resume() }
            accountWaiters.removeAll()
            return try await withCheckedThrowingContinuation { accountContinuation = $0 }
        }
        return resultUser
    }
    func guilds(token: String) async throws -> [DiscordGuild] {
        guildCalls += 1
        if let error { throw error }
        return resultGuilds
    }
    func waitForAccountStart() async {
        if !accountStarted { await withCheckedContinuation { accountWaiters.append($0) } }
    }
    func resumeAccount() { accountGate = false; accountContinuation?.resume(returning: resultUser!); accountContinuation = nil }
    func replaceGuilds(_ guilds: [DiscordGuild]) { resultGuilds = guilds }
    func fail(with error: TransportError) { self.error = error }
    func accountCallCount() -> Int { accountCalls }
    func guildsCallCount() -> Int { guildCalls }
}
