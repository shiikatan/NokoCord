import SwiftUI
import Observation
import AuthenticationServices
import Security
import LocalAuthentication

struct MLCredentials: Codable, Sendable, CustomStringConvertible {
    let accessToken: String
    let expiresAt: Date
    let userID: Int
    let userName: String
    var description: String { "MLCredentials(<redacted>)" }
}

protocol MLCredentialStore: Sendable {
    func load() async throws -> MLCredentials?
    func loadSilently() async throws -> MLCredentials?
    func save(_ credentials: MLCredentials) async throws
    func remove() async throws
}

extension MLCredentialStore {
    // Preparation must never prompt for credentials. Stores without an explicit
    // noninteractive implementation opt out rather than falling back to load().
    func loadSilently() async throws -> MLCredentials? { throw MLError.keychain }
}

/// macOS credential approval can outlive a disabled runtime. Share only the
/// in-flight read so re-enabling cannot open another prompt for the same item.
/// Completed credentials are never cached here.
actor MLCredentialReadCoalescer {
    private struct Flight { let id: UUID; let revision: UInt; let task: Task<MLCredentials?, Error> }
    private var flight: Flight?
    private var revision: UInt = 0
    // Keep a pending OS read installed while invalidating its result. A new
    // consumer must not open a second approval prompt during an account change.
    func mutate(operation: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        revision &+= 1
        try operation()
    }
    // A silent read is serialized with writes but never joins an interactive
    // flight: launch preparation must not wait for a user approval prompt.
    func loadSilently(operation: @Sendable () throws -> MLCredentials?) throws -> MLCredentials? {
        try Task.checkCancellation()
        return try operation()
    }
    func load(operation: @escaping @Sendable () async throws -> MLCredentials?) async throws -> MLCredentials? {
        try Task.checkCancellation()
        let selected: Flight
        if let flight { selected = flight }
        else {
            selected = Flight(id: UUID(), revision: revision, task: Task.detached(priority: .userInitiated) { try await operation() })
            flight = selected
        }
        do {
            let value = try await selected.task.value
            if flight?.id == selected.id { flight = nil }
            try Task.checkCancellation()
            guard revision == selected.revision else { throw MLError.keychain }
            return value
        } catch {
            if flight?.id == selected.id { flight = nil }
            throw error
        }
    }
}

actor MLKeychain: MLCredentialStore {
    private static let reads = MLCredentialReadCoalescer()
    private nonisolated static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.shiikatan.nokocord.maomao.maolist", kSecAttrAccount as String: "authorization"]
    }
    func load() async throws -> MLCredentials? {
        try await Self.reads.load { try Self.read(interactive: true) }
    }
    func loadSilently() async throws -> MLCredentials? {
        try await Self.reads.loadSilently { try Self.read(interactive: false) }
    }
    private nonisolated static func read(interactive: Bool) throws -> MLCredentials? {
        var query = Self.query
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(MLCredentials.self, from: data) else { throw MLError.keychain }
        return credentials
    }
    func save(_ credentials: MLCredentials) async throws {
        try Task.checkCancellation()
        try await Self.reads.mutate { try Self.write(credentials) }
    }
    private nonisolated static func write(_ credentials: MLCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "MaoList AniList connection"]
        let status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MLError.keychain }
        var item = Self.query.merging(values) { _, new in new }
        var access: SecAccess?
        guard SecAccessCreate("MaoList AniList connection" as CFString, nil, &access) == errSecSuccess, let access else { throw MLError.keychain }
        item[kSecAttrAccess as String] = access
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MLError.keychain }
    }
    func remove() async throws {
        try Task.checkCancellation()
        try await Self.reads.mutate {
            let status = SecItemDelete(Self.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MLError.keychain }
        }
    }
}

enum MLSection: String, CaseIterable, Identifiable { case home = "Home", anime = "Anime", manga = "Manga", discover = "Discover", activity = "Activity"; var id: String { rawValue } }
enum MLRoute: Hashable { case media(Int), activity(Int), review(Int), profile(Int), character(Int), staff(Int), studio(Int), notifications }

/// The only always-present object holds a toggle and an optional runtime.
/// Off has no session, Keychain read, observers, images, models or tasks.
@MainActor @Observable
final class MaoListModule {
    static let version = "ML1.0.0"
    static let preferenceKey = "maomaoMaoListEnabled"
    static let preparationPreferenceKey = "maomaoMaoListPrepareAtLaunch"
    private(set) var runtime: MLRuntime?
    private(set) var enabled: Bool
    private(set) var prepareAtLaunch: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let supported: Bool
    @ObservationIgnored private let makeRuntime: @MainActor () -> MLRuntime
    init(defaults: UserDefaults = .standard, supported: Bool = EditionIdentity.current?.id == "maomao", makeRuntime: @escaping @MainActor () -> MLRuntime = { MLRuntime() }) {
        self.defaults = defaults; self.supported = supported; self.makeRuntime = makeRuntime
        enabled = supported && defaults.bool(forKey: Self.preferenceKey)
        prepareAtLaunch = supported && defaults.bool(forKey: Self.preparationPreferenceKey)
        if enabled {
            runtime = makeRuntime()
            if prepareAtLaunch { runtime?.prepareSections() }
        }
    }
    func setEnabled(_ value: Bool) {
        guard supported, value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        if value {
            runtime = makeRuntime()
            if prepareAtLaunch { runtime?.prepareSections() }
        }
        else {
            runtime?.stop()
            runtime = nil
        }
    }
    func setPrepareAtLaunch(_ value: Bool) {
        guard supported, value != prepareAtLaunch else { return }
        prepareAtLaunch = value
        defaults.set(value, forKey: Self.preparationPreferenceKey)
        if value, enabled { runtime?.prepareSections() }
        else { runtime?.cancelPreparation() }
    }
}

@MainActor @Observable
final class MLHomeState {
    private(set) var data: MLHomeData?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var stale: Date?
    private(set) var partial = false
    private(set) var freshRevision = -1
    @ObservationIgnored private var loadedAt = Date.distantPast
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var lease = UUID()
    @discardableResult
    func load(repository: MLRepository, userID: Int, revision: Int, refresh: Bool = false) async -> MLResult<MLHomeData>? {
        if !refresh, let data, self.revision == revision, Date().timeIntervalSince(loadedAt) < 300 {
            return MLResult(value: data, cachedAt: stale, isPartial: partial)
        }
        let request = UUID(); lease = request; loading = true; error = nil
        defer { if lease == request { loading = false } }
        do {
            let result = try await repository.home(userID: userID, refresh: refresh)
            try Task.checkCancellation()
            if lease == request {
                data = result.value; stale = result.cachedAt; partial = result.isPartial
                self.revision = revision; loadedAt = Date()
                if result.cachedAt == nil && !result.isPartial { freshRevision = revision }
            }
            return result
        } catch {
            if lease == request, !(error is CancellationError), !Task.isCancelled {
                self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription
            }
            return nil
        }
    }
    func clear() { lease = UUID(); data = nil; loading = false; error = nil; stale = nil; partial = false; revision = -1; freshRevision = -1; loadedAt = .distantPast }
}

@MainActor @Observable
final class MLRuntime: NSObject, ASWebAuthenticationPresentationContextProviding {
    let repository: MLRepository
    let images = MLImageLoader()
    let home = MLHomeState()
    var section: MLSection = .home
    var animeListStatus: MLListStatus? = .current
    var mangaListStatus: MLListStatus? = .current
    var routes: [MLRoute] = []
    var search = MLSearchFilters()
    var searching = false
    var searchConfigured = false
    var searchSubmissionRevision = 0
    private(set) var viewer: MLUser?
    private(set) var connecting = false
    private(set) var restoring = true
    private(set) var needsReconnect = false
    var accountError: String?
    var mutationRevision = 0
    var discordPalette: MLDiscordPalette?
    private(set) var preparationStatus: String?
    private(set) var preparing = false
    private(set) var preparedLibraryPages: [String: Int] = [:]
    func preparedPageCount(type: MLMediaType, status: MLListStatus?) -> Int {
        preparedLibraryPages["\(type.rawValue)/\(status?.rawValue ?? "all")"] ?? 0
    }
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationLease = UUID()
    @ObservationIgnored private var preparationStarted = false
    @ObservationIgnored private var restorationSilent = false
    @ObservationIgnored private var foregroundRestoreRequested = false
    // Only actual text edits set this deadline. Submit/Apply/navigation clear it.
    @ObservationIgnored var searchTypingDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var credentials: MLCredentials?
    @ObservationIgnored private let keychain: any MLCredentialStore
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var restorationStarted = false
    @ObservationIgnored private var viewerLoadedAt = Date.distantPast
    @ObservationIgnored private var viewerRevision = -1
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private(set) var stopped = false

    override convenience init() { self.init(client: MLGraphQLClient(), keychain: MLKeychain()) }
    init(client: MLGraphQLClient, keychain: any MLCredentialStore) {
        repository = MLRepository(client: client)
        self.keychain = keychain
        super.init()
    }
    func beginRestoreConnection() {
        guard !stopped else { return }
        if restorationStarted {
            if restorationSilent { foregroundRestoreRequested = true }
            return
        }
        startRestore(silently: false)
    }
    private func startRestore(silently: Bool) {
        guard !stopped, !restorationStarted else { return }
        restorationStarted = true; restorationSilent = silently; restoring = true
        let keychain = keychain, client = repository.client
        accountTask = Task { [weak self, keychain, client] in
            await client.setAuthenticationFailureHandler { [weak self] in
                Task { @MainActor [weak self] in self?.handle(MLError.authentication) }
            }
            do {
                // Keychain may wait for the user. Do not retain the runtime,
                // views or artwork cache across that external wait.
                let saved = try await (silently ? keychain.loadSilently() : keychain.load())
                try Task.checkCancellation()
                guard let self, !self.stopped else { return }
                await self.restore(saved)
                self.restorationSilent = false
            } catch {
                guard let self, !self.stopped, !(error is CancellationError) else { return }
                self.restoring = false
                self.restorationSilent = false
                if silently {
                    self.restorationStarted = false
                    if self.foregroundRestoreRequested {
                        self.foregroundRestoreRequested = false
                        self.beginRestoreConnection()
                    }
                } else { self.accountError = MLError.keychain.localizedDescription }
            }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        cancelPreparation()
        preparedLibraryPages.removeAll()
        generation = UUID()
        accountTask?.cancel(); accountTask = nil
        authSession?.cancel(); authSession = nil
        images.stop()
        home.clear()
        repository.client.close()
        credentials = nil; viewer = nil; routes.removeAll(); discordPalette = nil
        let client = repository.client
        Task { await client.stop() }
    }
    func suspend() {
        // Explicit launch preparation is a bounded exception to the default
        // hidden-workspace policy. Ordinary hidden views still cancel their work.
        guard !preparing else { return }
        images.suspend()
        let client = repository.client
        Task { await client.cancelRequests() }
    }
    /// One finite, opt-in preparation pass. Library pages go through the same
    /// bounded account cache and exact queries as foreground navigation.
    func prepareSections() {
        guard !stopped, !connecting, !preparationStarted else { return }
        preparationStarted = true; preparing = true
        preparationStatus = "Preparing your connection…"
        let lease = UUID(); preparationLease = lease
        preparationTask = Task(priority: .utility) { [weak self] in
            // A system credential read may outlive cancellation. Keep only its
            // task across that wait so disabling releases the runtime/images.
            if self?.restorationStarted == false { self?.startRestore(silently: true) }
            let restoration = self?.accountTask
            await restoration?.value
            guard let self else { return }
            defer {
                if self.preparationLease == lease { self.preparing = false; self.preparationTask = nil }
            }
            do {
                try Task.checkCancellation()
                guard !self.stopped, self.preparationLease == lease else { return }
                guard let userID = self.viewer?.id else {
                    self.preparationStatus = "Open MaoList to prepare your account."
                    return
                }
                self.preparationStatus = "Preparing Home…"
                let preparedHome = await self.home.load(repository: self.repository, userID: userID, revision: self.mutationRevision)
                try Task.checkCancellation()
                guard let preparedHome, !preparedHome.isPartial, !preparedHome.isStale else { throw MLError.unavailable }
                let data = preparedHome.value
                if let user = data.Viewer { self.applyViewer(user) }
                let watching = data.watching?.mediaList?.compactMap { $0?.media } ?? []
                let reading = data.reading?.mediaList?.compactMap { $0?.media } ?? []
                let discovery = data.discovery?.media?.compactMap { $0 } ?? []
                let covers: [(URL?, Int)] = watching.prefix(3).map { ($0.coverImage?.medium ?? $0.coverImage?.large, 156) }
                    + reading.prefix(1).map { ($0.coverImage?.medium ?? $0.coverImage?.large, 156) }
                    + discovery.prefix(4).map { ($0.coverImage?.large, 396) }
                // Cover latency must not hold up section data. First-page batches
                // include default Anime, Manga, Discover and Activity together.
                let entries = MLPreparationEntry.all
                var remaining: [(MLMediaType, MLListStatus?)] = []
                for start in stride(from: 0, to: entries.count, by: 4) {
                    try Task.checkCancellation()
                    self.preparationStatus = "Preparing sections \(start + 1)–\(min(start + 4, entries.count)) of \(entries.count)…"
                    let batch = Array(entries[start..<min(start + 4, entries.count)])
                    let pages = try await self.repository.prepareFirstPages(batch, userID: userID)
                    try Task.checkCancellation()
                    for (entry, page) in zip(batch, pages) {
                        if case .library(let type, let status) = entry.kind {
                            self.preparedLibraryPages["\(type.rawValue)/\(status?.rawValue ?? "all")"] = 1
                            if page.pageInfo?.hasNextPage == true { remaining.append((type, status)) }
                        }
                    }
                }
                for (type, status) in remaining {
                    var page = 2
                    while true {
                        try Task.checkCancellation()
                        self.preparationStatus = "Preparing \(type.title.lowercased()) · \(status?.title(for: type) ?? "All") · page \(page)…"
                        let epoch = await self.repository.client.preparationEpoch()
                        let result = try await self.repository.library(userID: userID, type: type, status: status, page: page)
                        try Task.checkCancellation()
                        guard !result.isPartial, !result.isStale, let loaded = result.value.Page else { throw MLError.unavailable }
                        var variables: [String: MLValue] = ["user": .int(userID), "type": .string(type.rawValue), "page": .int(page)]
                        if let status { variables["status"] = .string(status.rawValue) }
                        try await self.repository.client.cachePrepared(MLRepository.libraryQuery, variables: variables, value: result.value, epoch: epoch)
                        self.preparedLibraryPages["\(type.rawValue)/\(status?.rawValue ?? "all")"] = page
                        if loaded.pageInfo?.hasNextPage != true { break }
                        guard page < 200 else { throw MLError.unavailable }
                        page += 1
                    }
                }
                self.preparationStatus = "Finishing Home artwork…"
                for (url, pixels) in covers {
                    try Task.checkCancellation()
                    _ = await self.images.image(url, pixels: pixels)
                }
                try Task.checkCancellation()
                self.preparationStatus = "Preparation finished."
            } catch {
                if self.preparationLease == lease, !self.stopped, !Task.isCancelled {
                    self.preparationStatus = "Preparation stopped. Remaining sections will load when opened."
                }
            }
        }
    }
    func cancelPreparation() {
        preparationLease = UUID()
        preparationTask?.cancel(); preparationTask = nil
        preparationStarted = false; preparing = false; preparationStatus = nil
        if restorationSilent {
            accountTask?.cancel(); accountTask = nil
            restorationSilent = false; restorationStarted = false; restoring = false
        }
    }

    private func restore(_ saved: MLCredentials?) async {
        defer { restoring = false }
        let lease = generation
        guard let saved, !stopped else { return }
        guard saved.expiresAt > Date() else { needsReconnect = true; return }
        credentials = saved
        await repository.client.authorize(token: saved.accessToken, accountID: saved.userID)
        guard !stopped, lease == generation else { return }
        viewer = MLUser(id: saved.userID, name: saved.userName)
        // A locked Keychain can defer startup work until the one foreground read.
        if preparationStarted, !preparing {
            preparationStarted = false
            prepareSections()
        }
    }
    func refreshViewer() async {
        guard !stopped, viewer != nil, !connecting else { return }
        guard viewerRevision != mutationRevision || Date().timeIntervalSince(viewerLoadedAt) >= 300 else { return }
        do {
            let result = try await repository.viewer()
            try Task.checkCancellation()
            guard !stopped else { return }
            if let user = result.value.Viewer { applyViewer(user, partial: result.isPartial) }
        } catch { handle(error) }
    }
    func applyViewer(_ user: MLUser, partial: Bool = false) {
        guard !stopped, viewer?.id == user.id else { return }
        viewer = user
        if !partial { viewerLoadedAt = Date(); viewerRevision = mutationRevision }
    }
    func connect() {
        guard !stopped, !connecting, !restoring else { return }
        cancelPreparation()
        preparedLibraryPages.removeAll()
        accountError = nil
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "NokoAniListClientID") as? String,
              Int(clientID) != nil else { accountError = MLError.configuration.localizedDescription; return }
        connecting = true
        let lease = generation
        accountTask = Task { [weak self] in
            guard let self else { return }
            defer { if lease == self.generation { self.connecting = false; self.authSession = nil; self.accountTask = nil } }
            do {
                let nonce = UUID().uuidString + UUID().uuidString
                var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
                components.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "token"), URLQueryItem(name: "state", value: nonce)]
                let callback: URL = try await withCheckedThrowingContinuation { continuation in
                    let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "nokocord-maolist") { url, error in
                        if let url { continuation.resume(returning: url) }
                        else { continuation.resume(throwing: error ?? CancellationError()) }
                    }
                    session.presentationContextProvider = self
                    session.prefersEphemeralWebBrowserSession = true
                    self.authSession = session
                    if !session.start() { self.authSession = nil; continuation.resume(throwing: MLError.unavailable) }
                }
                try Task.checkCancellation()
                guard lease == self.generation, !self.stopped else { throw CancellationError() }
                let authorization = try MLAuthorization(callback: callback, expectedState: nonce)
                await self.repository.client.authorize(token: authorization.accessToken, accountID: nil)
                guard let user = try await self.repository.viewer(refresh: true).value.Viewer else { throw MLError.authentication }
                try Task.checkCancellation()
                guard !self.stopped, lease == self.generation else { throw CancellationError() }
                let saved = MLCredentials(accessToken: authorization.accessToken, expiresAt: Date().addingTimeInterval(authorization.lifetime), userID: user.id, userName: user.name ?? "AniList")
                if let oldID = self.credentials?.userID, oldID != user.id {
                    try await Task.detached(priority: .utility) { try MLDiskCache.removeAccountData() }.value
                    await self.images.removeDiskData()
                }
                try await self.keychain.save(saved)
                guard !self.stopped, lease == self.generation else { return }
                self.credentials = saved
                await self.repository.client.authorize(token: saved.accessToken, accountID: user.id)
                self.viewer = user; self.needsReconnect = false; self.routes.removeAll(); self.section = .home
                self.home.clear()
                self.mutationRevision += 1
            } catch {
                if !self.stopped, lease == self.generation {
                    await self.repository.client.authorize(token: self.credentials?.accessToken, accountID: self.credentials?.userID)
                    let sessionError = error as NSError
                    let cancelled = sessionError.domain == ASWebAuthenticationSessionError.errorDomain && sessionError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
                    if !cancelled && !(error is CancellationError) {
                        self.accountError = (error as? MLError)?.localizedDescription ?? MLError.authentication.localizedDescription
                    }
                }
            }
        }
    }
    func cancelConnect() { accountTask?.cancel(); authSession?.cancel() }
    func disconnect() async {
        guard !stopped else { return }
        cancelPreparation()
        preparedLibraryPages.removeAll()
        cancelConnect()
        generation = UUID()
        connecting = false
        await repository.client.cancelRequests()
        do {
            try await keychain.remove()
            credentials = nil; viewer = nil; needsReconnect = false
            home.clear()
            await repository.client.resetAccount()
            await images.removeDiskData()
            try await Task.detached(priority: .utility) { try MLDiskCache.removeAccountData() }.value
            routes.removeAll(); section = .home; mutationRevision += 1; accountError = nil
        } catch { accountError = (error as? MLError)?.localizedDescription ?? "The saved connection was removed, but some local data could not be cleared. Please retry Disconnect." }
    }
    func handle(_ error: Error) {
        guard !stopped, !(error is CancellationError) else { return }
        if error as? MLError == .authentication {
            cancelPreparation(); preparedLibraryPages.removeAll()
            needsReconnect = true; viewer = nil; credentials = nil; routes.removeAll(); mutationRevision += 1
            home.clear()
        }
    }
    func didMutate() { cancelPreparation(); preparedLibraryPages.removeAll(); mutationRevision += 1 }
    func applyListPreferences(_ user: MLUser) {
        guard !stopped, var current = viewer, current.id == user.id else { return }
        current.mediaListOptions = user.mediaListOptions
        viewer = current
        didMutate()
    }
    func seedSearchFromSection() {
        guard !searching, !searchConfigured, search.term.isEmpty, !search.hasFilters else { return }
        search.type = section == .manga ? .manga : .anime
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
