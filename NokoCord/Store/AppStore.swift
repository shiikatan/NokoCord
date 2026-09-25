import AppKit
import Network
import Observation

@MainActor @Observable
final class AppStore {
    var state: ConnectionState = .signedOut
    var user: DiscordUser?
    var guilds: [DiscordGuild] = []
    private(set) var accountUpdatedAt: Date?
    private(set) var accountLoadedFromCache = false
    var canRefresh: Bool { !state.isBusy && networkIsAvailable && credentials != nil }
    var selectedGuildID: String?
    var searchText = ""
    // Windows own their presentation state; this invalidates account-scoped UI
    // in every window without sharing a sheet binding between them.
    private(set) var accountPresentationID = UUID()
    var brokerURL: String {
        didSet {
            // Keep partially typed text only in memory. Persist only a validated
            // origin, never URL credentials, paths, queries or fragments.
            if brokerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preferences.removeObject(forKey: "brokerURL")
            } else if let origin = try? BrokerConfiguration.origin(brokerURL) {
                preferences.set(origin.absoluteString, forKey: "brokerURL")
            }
        }
    }
    private(set) var draftCleanupMessage: String?
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var selectedGuild: DiscordGuild? { guilds.first { $0.id == selectedGuildID } }
    var filteredGuilds: [DiscordGuild] {
        guard !searchText.isEmpty else { return guilds }
        return guilds.filter { $0.name.localizedStandardContains(searchText) }
    }
    @ObservationIgnored private let clearNotifications: () -> Void
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let draftStore: DraftStore
    @ObservationIgnored private let clearAvatars: @Sendable () async -> Void
    @ObservationIgnored private let rest: any AccountFetching
    @ObservationIgnored private let keychain: any CredentialPersisting
    @ObservationIgnored private let cache: any AccountCaching
    @ObservationIgnored private let authentication: any SessionAuthenticating
    @ObservationIgnored private var credentials: OAuthCredentials?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var restored = false
    private(set) var networkIsAvailable = true
    @ObservationIgnored private var history: [String?] = [nil]
    @ObservationIgnored private var historyIndex = 0
    init(authentication: (any SessionAuthenticating)? = nil,
         keychain: any CredentialPersisting = CredentialStore(),
         cache: any AccountCaching = AccountCache(),
         rest: (any AccountFetching)? = nil,
         monitorNetwork: Bool = true,
         clearNotifications: @escaping () -> Void = {},
         clearAvatars: (@Sendable () async -> Void)? = nil,
         preferences: UserDefaults = .standard,
         draftStore: DraftStore = .shared) {
        self.preferences = preferences
        self.draftStore = draftStore
        self.clearNotifications = clearNotifications
        self.clearAvatars = clearAvatars ?? { await AvatarPipeline.shared.clear() }
        let http = HTTPClient()
        self.authentication = authentication ?? Authentication(http: http)
        self.keychain = keychain
        self.cache = cache
        self.rest = rest ?? DiscordREST(http: http)
        let savedOrigin = preferences.string(forKey: "brokerURL") ?? ""
        brokerURL = (try? BrokerConfiguration.origin(savedOrigin).absoluteString) ?? ""
        if brokerURL.isEmpty { preferences.removeObject(forKey: "brokerURL") }
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkPathChanged(isAvailable: path.status == .satisfied)
            }
        }
        if monitorNetwork { network.start(queue: DispatchQueue(label: "com.nokocord.network", qos: .utility)) }
    }
    deinit { network.cancel(); operation?.cancel() }
    func signIn() {
        restored = true
        guard !state.isBusy else { return }
        let origin: URL
        do { origin = try BrokerConfiguration.origin(brokerURL) }
        catch { state = .failed(error.localizedDescription); return }
        begin()
        let id = generation
        state = .authenticating
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let received = try await self.authentication.signIn(origin: origin)
                try Task.checkCancellation()
                guard self.generation == id else { return }
                try self.keychain.save(received)
                self.clearNotifications()
                self.credentials = received
                self.user = nil; self.guilds = []; self.resetAccountPresentation()
                try await self.loadAccount(id: id)
            } catch { await self.handle(error, id: id) }
        }
    }
    func refresh() {
        guard canRefresh else { return }
        begin()
        let id = generation
        state = .loading
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await self.loadAccount(id: id) }
            catch { await self.handle(error, id: id) }
        }
    }
    func networkPathChanged(isAvailable: Bool) {
        networkIsAvailable = isAvailable
        guard credentials != nil else { return }
        if !isAvailable {
            // Invalidate buffered results as well as cancelling transport work.
            // A late response must not turn an offline session back to connected.
            begin()
            state = .offline
        } else if state == .offline { refresh() }
    }
    func clearCache() async {
        begin()
        let id = generation
        state = credentials == nil ? .signedOut : (!networkIsAvailable || user == nil ? .offline : .connected)
        do {
            try await cache.clear()
            guard generation == id else { return }
            await clearAvatars()
        } catch {
            guard generation == id else { return }
            state = .failed(String(localized: "The local cache could not be cleared. Retry from Settings."))
        }
    }
    func clearRetainedDrafts() async {
        do {
            try await draftStore.clearAll()
            draftCleanupMessage = String(localized: "Saved drafts deleted. Your Discord session was not changed.")
        } catch {
            draftCleanupMessage = String(localized: "Saved drafts could not be deleted. Try again.")
        }
    }
    func signOut() {
        restored = true
        begin()
        clearNotifications()
        let previous = credentials
        credentials = nil
        user = nil
        guilds = []
        resetAccountPresentation()
        var keychainFailed = false
        do { try keychain.delete(); state = .signedOut }
        catch { keychainFailed = true; state = .failed(String(localized: "Profile disconnected, but saved credential cleanup failed. Retry Disconnect Profile before quitting.")) }
        let id = generation
        operation = Task { [weak self] in
            guard let self else { return }
            var cleanupFailed = false
            do { try await self.cache.clear() }
            catch { cleanupFailed = true }
            await self.clearAvatars()
            var revocationFailed = false
            if let previous {
                do { try await self.authentication.revoke(previous) }
                catch { revocationFailed = true }
            }
            guard self.generation == id else { return }
            if keychainFailed {
                self.state = .failed(String(localized: "Keychain cleanup failed. Retry Disconnect Profile before quitting; saved credentials may remain on this Mac."))
            } else if cleanupFailed {
                self.state = .failed(String(localized: "Local account cache cleanup failed. Retry Disconnect Profile. Remove NokoCord from Discord’s Authorized Apps if remote revocation is uncertain."))
            } else if revocationFailed {
                self.state = .failed(String(localized: "Remote revocation failed. Remove NokoCord in Discord’s Authorized Apps settings. Local credentials and cached account data were removed unless a prior Keychain error was shown."))
            }
        }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        let id = generation
        do {
            credentials = try keychain.load()
            if let credentials {
                if let snapshot = try? await cache.load(), snapshot.account.id == credentials.accountID {
                    guard generation == id else { return }
                    user = snapshot.account; guilds = snapshot.guilds
                    accountUpdatedAt = snapshot.savedAt; accountLoadedFromCache = true
                }
                guard generation == id else { return }
                if networkIsAvailable { refresh() } else { state = .offline }
            } else { clearNotifications(); try? await cache.clear() }
        } catch { state = .failed(String(localized: "The saved session could not be read. Sign out to clear it, then sign in again.")) }
    }
    func selectGuild(_ id: String?) {
        guard id != selectedGuildID, id == nil || guilds.contains(where: { $0.id == id }) else { return }
        selectedGuildID = id
        history = Array(history.prefix(historyIndex + 1))
        history.append(id)
        if history.count > 100 { history.removeFirst() }
        historyIndex = history.count - 1
    }
    private func resetAccountPresentation() {
        accountUpdatedAt = nil; accountLoadedFromCache = false
        selectedGuildID = nil
        history = [nil]; historyIndex = 0
        searchText = ""
        accountPresentationID = UUID()
    }
    private func reconcileNavigation() {
        let available = Set(guilds.map(\.id))
        var reconciled: [String?] = []
        var currentIndex = 0
        for (index, entry) in history.enumerated() {
            let destination = entry.flatMap { available.contains($0) ? $0 : nil }
            if reconciled.isEmpty || reconciled.last! != destination { reconciled.append(destination) }
            if index == historyIndex { currentIndex = reconciled.count - 1 }
        }
        history = reconciled
        historyIndex = currentIndex
        selectedGuildID = history[historyIndex]
    }
    func goBack() { guard historyIndex > 0 else { return }; historyIndex -= 1; selectedGuildID = history[historyIndex] }
    func goForward() { guard historyIndex + 1 < history.count else { return }; historyIndex += 1; selectedGuildID = history[historyIndex] }
    func cancelSignIn() { begin(); state = credentials == nil ? .signedOut : (!networkIsAvailable || user == nil ? .offline : .connected) }
    func waitForCurrentOperation() async { await operation?.value }
    private func begin() { generation = UUID(); operation?.cancel(); authentication.cancel() }
    private func loadAccount(id: UUID) async throws {
        guard var active = credentials else { throw TransportError.unauthorized }
        guard networkIsAvailable else { throw URLError(.notConnectedToInternet) }
        state = .loading
        if active.expiresAt.timeIntervalSinceNow < 120 {
            active = try await authentication.refresh(active)
            try Task.checkCancellation()
            guard generation == id else { return }
            try keychain.save(active)
            credentials = active
        }
        let rest = self.rest
        let accessToken = active.accessToken
        async let account = rest.account(token: accessToken)
        async let servers = rest.guilds(token: accessToken)
        let result = try await (account, servers)
        try Task.checkCancellation()
        guard generation == id else { return }
        active.accountID = result.0.id
        try keychain.save(active)
        credentials = active
        user = result.0
        guilds = result.1
        accountUpdatedAt = Date(); accountLoadedFromCache = false
        reconcileNavigation()
        try? await cache.save(account: result.0, guilds: result.1)
        guard generation == id else { return }
        state = .connected
    }
    private func handle(_ error: Error, id: UUID) async {
        guard generation == id else { return }
        if error is CancellationError || (error as? TransportError) == .cancelled {
            state = credentials == nil ? .signedOut : (!networkIsAvailable || user == nil ? .offline : .connected)
        } else if (error as? TransportError) == .unauthorized {
            clearNotifications()
            credentials = nil; user = nil; guilds = []; resetAccountPresentation()
            do { try keychain.delete(); state = .invalidSession }
            catch { state = .failed(String(localized: "Authorization is invalid and Keychain cleanup failed. Retry Disconnect Profile.")) }
            try? await cache.clear()
            guard generation == id else { return }
            await clearAvatars()
        } else if let failure = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(failure.code) {
            state = .offline
        } else if let failure = error as? TransportError {
            state = .failed(failure.localizedDescription)
        } else { state = .failed(String(localized: "The account could not be loaded. Retry or sign in again.")) }
    }
}
