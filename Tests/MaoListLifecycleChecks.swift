import Foundation
import AppKit

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Bool] = [:]
    private let lock = NSLock()
    override func bool(forKey key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[key] ?? false }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value as? Bool }
}

private actor MemoryCredentials: MLCredentialStore {
    private var stored: MLCredentials?
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var removals = 0
    init(_ stored: MLCredentials? = nil) { self.stored = stored }
    func load() -> MLCredentials? { loads += 1; return stored }
    func loadSilently() -> MLCredentials? { loads += 1; return stored }
    func save(_ credentials: MLCredentials) { saves += 1; stored = credentials }
    func remove() { removals += 1; stored = nil }
}

private actor WaitingCredentials: MLCredentialStore {
    private(set) var started = false
    private(set) var loads = 0
    private var continuation: CheckedContinuation<MLCredentials?, Never>?
    func load() async -> MLCredentials? {
        loads += 1
        return await withCheckedContinuation { continuation = $0; started = true }
    }
    func save(_ credentials: MLCredentials) {}
    func remove() {}
    func finish(_ value: MLCredentials? = nil) { continuation?.resume(returning: value); continuation = nil }
}

private struct CoalescedWaitingCredentials: MLCredentialStore {
    let reads: MLCredentialReadCoalescer
    let source: WaitingCredentials
    func load() async throws -> MLCredentials? { try await reads.load { await source.load() } }
    func save(_ credentials: MLCredentials) async {}
    func remove() async {}
}

private struct SilentWaitingCredentials: MLCredentialStore {
    let source: WaitingCredentials
    func load() async -> MLCredentials? { await source.load() }
    func loadSilently() async -> MLCredentials? { await source.load() }
    func save(_ credentials: MLCredentials) async {}
    func remove() async {}
}

private final class NoNetworkProtocol: URLProtocol, @unchecked Sendable {
    static var requests = 0
    static var unauthorized = false
    static var responseBody: String?
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        if Self.unauthorized {
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"errors\":[{\"status\":401}]}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else if let body = Self.responseBody {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {}
}

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var count = 0
    static var data = Data()
    private var work: DispatchWorkItem?
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let data = Self.data; Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

@main private struct MaoListLifecycleChecks {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "MaoListLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func settle(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(predicate(), "Module state did not settle")
    }
    @MainActor static func main() async throws {
        let defaults = MemoryDefaults()
        let credentials = MemoryCredentials()
        var created = 0
        weak var runtime: MLRuntime?
        weak var images: MLImageLoader?
        let module = MaoListModule(defaults: defaults, supported: true) {
            created += 1
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NoNetworkProtocol.self]
            let client = MLGraphQLClient(session: URLSession(configuration: config), minimumSpacing: 0)
            let value = MLRuntime(client: client, keychain: credentials)
            runtime = value; images = value.images
            return value
        }
        try require(!module.enabled && module.runtime == nil && created == 0, "Disabled launch constructed runtime services")
        let initialLoads = await credentials.loads
        try require(initialLoads == 0 && NoNetworkProtocol.requests == 0, "Disabled launch read credentials or sent a request")
        print("PASS disabled launch creates no services, credential reads or API requests")
        for index in 1...10 {
            module.setEnabled(true)
            module.setEnabled(true)
            let loadsBeforeOpen = await credentials.loads
            try require(loadsBeforeOpen == index - 1, "Enabled but unopened module accessed Keychain")
            for _ in 0..<10 { module.runtime?.beginRestoreConnection() }
            try await settle { module.runtime?.restoring == false }
            try require(created == index, "Enable constructed duplicate runtime services")
            let retainedRepository = module.runtime!.repository
            module.setEnabled(false)
            try require(!module.enabled && module.runtime == nil, "Disable kept a runtime installed")
            do {
                _ = try await retainedRepository.search(MLSearchFilters(), page: 1)
                throw NSError(domain: "MaoListLifecycle", code: 2)
            } catch is CancellationError { }
            catch MLError.stopped { }
            try await settle { runtime == nil && images == nil }
            try require(NoNetworkProtocol.requests == 0, "Disabled module performed API networking")
        }
        let loads = await credentials.loads, saves = await credentials.saves, removals = await credentials.removals
        try require(loads == 10 && saves == 0 && removals == 0, "Toggle altered saved authentication")
        try require(defaults.bool(forKey: MaoListModule.preferenceKey) == false, "Injected preferences were not updated")
        print("PASS ten enable/disable cycles release runtime and artwork services without requests or credential changes")

        let waitingStore = WaitingCredentials()
        let waitingDefaults = MemoryDefaults()
        weak var waitingRuntime: MLRuntime?
        weak var waitingImages: MLImageLoader?
        let waitingModule = MaoListModule(defaults: waitingDefaults, supported: true) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NoNetworkProtocol.self]
            let value = MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), minimumSpacing: 0), keychain: waitingStore)
            waitingRuntime = value; waitingImages = value.images
            return value
        }
        waitingModule.setEnabled(true)
        for _ in 0..<10 { waitingModule.runtime?.beginRestoreConnection() }
        for _ in 0..<500 {
            if await waitingStore.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waitingStarted = await waitingStore.started
        try require(waitingStarted, "Credential wait fixture did not start")
        let waitingLoads = await waitingStore.loads
        try require(waitingLoads == 1, "Concurrent restoration requests prompted for the same credential more than once")
        waitingModule.setEnabled(false)
        try await settle { waitingRuntime == nil && waitingImages == nil }
        await waitingStore.finish()
        try require(NoNetworkProtocol.requests == 0, "Disabled credential wait issued requests")
        print("PASS disabling during credential approval releases runtime and artwork services")

        let startupWait = WaitingCredentials(), startupDefaults = MemoryDefaults()
        startupDefaults.set(true, forKey: MaoListModule.preferenceKey)
        startupDefaults.set(true, forKey: MaoListModule.preparationPreferenceKey)
        weak var startupRuntime: MLRuntime?, startupImages: MLImageLoader?
        let startupModule = MaoListModule(defaults: startupDefaults, supported: true) {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NoNetworkProtocol.self]
            let value = MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), minimumSpacing: 0),
                                  keychain: SilentWaitingCredentials(source: startupWait))
            startupRuntime = value; startupImages = value.images
            return value
        }
        for _ in 0..<100 { if await startupWait.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let startupReadStarted = await startupWait.started
        try require(startupReadStarted && startupModule.runtime?.preparing == true, "Startup credential wait fixture did not begin")
        startupModule.setEnabled(false)
        try await settle { startupRuntime == nil && startupImages == nil }
        await startupWait.finish()
        try require(NoNetworkProtocol.requests == 0, "Disabled startup credential wait issued API requests")
        print("PASS disabling startup preparation during credential wait releases runtime and artwork immediately")

        let sharedReads = MLCredentialReadCoalescer(), sharedSource = WaitingCredentials()
        let sharedDefaults = MemoryDefaults()
        let sharedModule = MaoListModule(defaults: sharedDefaults, supported: true) {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NoNetworkProtocol.self]
            return MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), minimumSpacing: 0),
                             keychain: CoalescedWaitingCredentials(reads: sharedReads, source: sharedSource))
        }
        sharedModule.setEnabled(true); sharedModule.runtime?.beginRestoreConnection()
        for _ in 0..<100 { if await sharedSource.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        weak var oldSharedRuntime = sharedModule.runtime
        sharedModule.setEnabled(false)
        try await settle { oldSharedRuntime == nil }
        sharedModule.setEnabled(true); sharedModule.runtime?.beginRestoreConnection()
        try await Task.sleep(for: .milliseconds(20))
        let sharedLoads = await sharedSource.loads
        try require(sharedLoads == 1, "Re-enabling during a pending credential read opened a second prompt")
        await sharedSource.finish(MLCredentials(accessToken: "shared-fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 17, userName: "SharedFixture"))
        try await settle { sharedModule.runtime?.restoring == false }
        try require(sharedModule.runtime?.viewer?.id == 17 && oldSharedRuntime == nil && NoNetworkProtocol.requests == 0, "Shared credentials did not restore only the surviving runtime")
        sharedModule.setEnabled(false)
        print("PASS pending credential approval is shared across runtime replacement without retaining the disabled runtime")

        for mutation in ["replacement", "deletion"] {
            let reads = MLCredentialReadCoalescer(), source = WaitingCredentials()
            let pending = Task { try await reads.load { await source.load() } }
            for _ in 0..<100 { if await source.started { break }; try await Task.sleep(for: .milliseconds(5)) }
            try await reads.mutate { }
            let joined = Task { try await reads.load { await source.load() } }
            try await Task.sleep(for: .milliseconds(20))
            let count = await source.loads
            try require(count == 1, "Account \(mutation) created a duplicate pending approval")
            let silent = try await reads.loadSilently { MLCredentials(accessToken: "silent-fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 20, userName: "SilentFixture") }
            try require(silent?.userID == 20, "Silent credential read joined a pending interactive approval")
            await source.finish(MLCredentials(accessToken: "obsolete-fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 18, userName: "ObsoleteFixture"))
            for result in [pending, joined] {
                do {
                    _ = try await result.value
                    try require(false, "Account \(mutation) delivered obsolete credentials")
                } catch MLError.keychain { }
            }
            let fresh = try await reads.load { MLCredentials(accessToken: "fresh-fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 19, userName: "FreshFixture") }
            try require(fresh?.userID == 19, "Invalidation prevented a later fresh credential read")
        }
        print("PASS account replacement/deletion invalidates pending credentials, preserves independent silent reads and permits a fresh read")


        defaults.set(true, forKey: MaoListModule.preferenceKey)
        let unsupported = MaoListModule(defaults: defaults, supported: false) { fatalError("Unsupported edition constructed MaoList") }
        unsupported.setEnabled(true)
        try require(!unsupported.enabled && unsupported.runtime == nil, "Unsupported edition enabled MaoList")
        print("PASS unsupported editions remain unloaded")

        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MaoListLifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        func makeAuthenticatedRuntime(using store: MemoryCredentials) -> MLRuntime {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NoNetworkProtocol.self]
            return MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), cacheBase: cacheRoot, minimumSpacing: 0), keychain: store)
        }
        let saved = MemoryCredentials(MLCredentials(accessToken: "fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 7, userName: "Fixture"))
        let connectedDefaults = MemoryDefaults()
        connectedDefaults.set(true, forKey: MaoListModule.preferenceKey)
        let connected = MaoListModule(defaults: connectedDefaults, supported: true) { makeAuthenticatedRuntime(using: saved) }
        connected.runtime?.beginRestoreConnection()
        try await settle { connected.runtime?.restoring == false }
        try require(connected.runtime?.viewer?.id == 7 && NoNetworkProtocol.requests == 0, "Saved connection did not restore locally")
        connected.setEnabled(false); connected.setEnabled(true)
        connected.runtime?.beginRestoreConnection()
        try await settle { connected.runtime?.restoring == false }
        let savedRemovals = await saved.removals, savedWrites = await saved.saves
        try require(connected.runtime?.viewer?.id == 7 && savedRemovals == 0 && savedWrites == 0 && NoNetworkProtocol.requests == 0, "Authenticated toggle lost credentials or started a background request")
        print("PASS saved authentication survives off/on without API calls or credential writes")

        NoNetworkProtocol.responseBody = "{\"data\":{\"Viewer\":{\"id\":7,\"name\":\"Fixture\"},\"watching\":{\"mediaList\":[]},\"reading\":{\"mediaList\":[]},\"discovery\":{\"media\":[]}}}"
        let home = connected.runtime!.home
        await home.load(repository: connected.runtime!.repository, userID: 7, revision: 0)
        try require(home.data?.Viewer?.id == 7 && home.data?.reading?.mediaList?.isEmpty == true && NoNetworkProtocol.requests == 1, "Combined home failed or sent more than one request")
        await home.load(repository: connected.runtime!.repository, userID: 7, revision: 0)
        try require(NoNetworkProtocol.requests == 1 && !home.loading && home.freshRevision == 0, "Returning to warm Home refetched its sections")
        let homeResponse = NoNetworkProtocol.responseBody
        NoNetworkProtocol.responseBody = nil
        await home.load(repository: connected.runtime!.repository, userID: 7, revision: 1, refresh: true)
        try require(home.data != nil && home.stale != nil && home.freshRevision == 0, "Offline Home fallback retired a newer saved entry")
        NoNetworkProtocol.responseBody = homeResponse
        await home.load(repository: connected.runtime!.repository, userID: 7, revision: 2, refresh: true)
        try require(home.freshRevision == 2 && home.stale == nil, "Fresh Home response did not supersede saved-entry overlays")
        home.clear()
        try require(home.data == nil && !home.loading && home.freshRevision == -1, "Home retained account models after cleanup")
        print("PASS one-request Home load, warm reuse, authoritative refresh revisions and account model cleanup")
        let characters = MLMediaSectionState()
        NoNetworkProtocol.responseBody = "{\"data\":{\"Media\":{\"id\":314}}}"
        await characters.load(repository: connected.runtime!.repository, mediaID: 314, section: .characters)
        try require(characters.page == 0 && characters.error != nil, "Missing section response advanced pagination or looked empty")
        NoNetworkProtocol.responseBody = "{\"data\":{\"Media\":{\"id\":314,\"characters\":{\"nodes\":[{\"id\":1}],\"pageInfo\":{\"hasNextPage\":true}}}}}"
        await characters.load(repository: connected.runtime!.repository, mediaID: 314, section: .characters)
        try require(characters.page == 1 && characters.error == nil && characters.next && characters.media?.characters?.items.count == 1, "Section retry reused a damaged cached response or lost its first page")
        NoNetworkProtocol.responseBody = "{\"data\":{\"Media\":{\"id\":314,\"characters\":{\"nodes\":[{\"id\":1},{\"id\":2}],\"pageInfo\":{\"hasNextPage\":false}}}}}"
        await characters.load(repository: connected.runtime!.repository, mediaID: 314, section: .characters)
        let staff = MLMediaSectionState()
        NoNetworkProtocol.responseBody = "{\"data\":{\"Media\":{\"id\":314,\"staff\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
        await staff.load(repository: connected.runtime!.repository, mediaID: 314, section: .staff)
        try require(characters.page == 2 && characters.media?.characters?.items.map(\.id) == [1, 2] && !characters.next && staff.page == 1 && staff.error == nil, "Separate section states lost retained pages or confused empty with incomplete data")
        print("PASS retained detail sections, deduplicated pagination, empty results and incomplete-response retry")
        NoNetworkProtocol.responseBody = nil
        NoNetworkProtocol.requests = 0

        NoNetworkProtocol.unauthorized = true
        await connected.runtime?.refreshViewer()
        try await settle { connected.runtime?.needsReconnect == true }
        try require(connected.runtime?.viewer == nil && NoNetworkProtocol.requests == 1, "Revoked authentication was not cleared from visible state")
        await connected.runtime?.refreshViewer()
        try require(NoNetworkProtocol.requests == 1, "Invalid connection repeatedly retried authentication")
        connected.setEnabled(false)
        print("PASS revoked authentication requires reconnect and does not retry")

        let expiredStore = MemoryCredentials(MLCredentials(accessToken: "expired-fixture", expiresAt: Date().addingTimeInterval(-1), userID: 8, userName: "Fixture"))
        let expired = makeAuthenticatedRuntime(using: expiredStore)
        expired.beginRestoreConnection()
        try await settle { !expired.restoring }
        try require(expired.needsReconnect && expired.viewer == nil && NoNetworkProtocol.requests == 1, "Expired connection contacted AniList or appeared connected")
        expired.stop()
        print("PASS expired authentication prompts reconnect without network access")
        let pages = MLPageStore()
        var pageRequests = 0
        func pageFixture(_ page: Int) throws -> MLResult<MLPageData> {
            pageRequests += 1
            let data = Data("{\"Page\":{\"media\":[{\"id\":\(page)}],\"pageInfo\":{\"hasNextPage\":true}}}".utf8)
            return MLResult(value: try JSONDecoder().decode(MLPageData.self, from: data), cachedAt: nil, isPartial: false)
        }
        await pages.loadInitial(key: "anime/current/7/0") { try pageFixture($0) }
        await pages.load { try pageFixture($0) }
        await pages.loadInitial(key: "anime/current/7/0") { try pageFixture($0) }
        try require(pageRequests == 2 && pages.page == 2 && pages.data.media?.count == 2, "Workspace return refetched or reset loaded pages")
        await pages.loadInitial(key: "anime/all/7/0") { try pageFixture($0) }
        try require(pageRequests == 3 && pages.page == 1 && pages.data.media?.count == 1, "Changed list reused a different status's entries")
        var attempts = 0
        await pages.loadInitial(key: "anime/all/7/1") { _ in attempts += 1; throw MLError.offline }
        await pages.loadInitial(key: "anime/all/7/1") { try pageFixture($0) }
        try require(attempts == 1 && pageRequests == 4 && pages.error == nil, "Failed load was incorrectly held as a successful warm page")
        print("PASS workspace return preserves pagination, status changes reload and failed initial loads remain retryable")

        let retainedIDs = pages.data.media?.compactMap { $0?.id }
        let updating = Task { await pages.loadInitial(key: "anime/all/7/1", refresh: true) { page in
            try await Task.sleep(for: .milliseconds(100))
            return try pageFixture(page)
        } }
        try await Task.sleep(for: .milliseconds(20))
        try require(pages.loading && pages.page > 0 && pages.data.media?.compactMap { $0?.id } == retainedIDs,
                    "Same-query refresh blanked visible entries")
        await updating.value
        try require(!pages.loading && pages.error == nil && pages.staleDate == nil, "Fresh replacement retained an updating/stale state")
        await pages.loadInitial(key: "anime/all/7/1", refresh: true) { _ in throw MLError.offline }
        try require(pages.page > 0 && pages.data.media?.compactMap { $0?.id } == retainedIDs && pages.error != nil,
                    "Failed same-query refresh discarded useful entries or hid the failure")
        let changed = Task { await pages.loadInitial(key: "manga/all/8/0") { page in
            try await Task.sleep(for: .milliseconds(100))
            return try pageFixture(page)
        } }
        try await Task.sleep(for: .milliseconds(20))
        try require(pages.loading && pages.page == 0 && pages.data.media == nil, "A different query/account displayed the previous entries")
        await changed.value
        print("PASS same-query refresh keeps entries visible, reports failure and clears immediately for different queries/accounts")

        await pages.load { try pageFixture($0) }
        await pages.load(reset: true, preservingData: true) { _ in throw MLError.offline }
        var retriedPage = 0
        await pages.load { page in retriedPage = page; return try pageFixture(page) }
        try require(retriedPage == 1 && pages.page == 1 && pages.data.media?.count == 1 && pages.error == nil,
                    "Retry after failed refresh appended a later page instead of retrying page one")
        print("PASS failed refresh retries the original page while preserving useful data")

        let explicitReads = MLReadActions()
        var readCompleted = false, readCancelled = false, hiddenReadStarted = false
        explicitReads.run {
            do { try await Task.sleep(for: .seconds(2)); readCompleted = true }
            catch { readCancelled = true }
        }
        try await Task.sleep(for: .milliseconds(20))
        explicitReads.setActive(false)
        try await settle { readCancelled }
        explicitReads.run { hiddenReadStarted = true }
        try await Task.sleep(for: .milliseconds(20))
        try require(!readCompleted && !hiddenReadStarted, "Hidden screen completed or started an explicit read")
        explicitReads.setActive(true)
        explicitReads.run { readCompleted = true }
        try await settle { readCompleted }
        print("PASS explicit read actions cancel on hiding, reject hidden work and resume when visible")

        let returningRequest = MLReadRequest(), delayedCancellation = WaitingCredentials()
        var visibleSectionPopulated = false
        let leavingSection = Task {
            guard let lease = returningRequest.begin() else { return }
            defer { returningRequest.finish(lease) }
            _ = await delayedCancellation.load() // Deliberately ignores cancellation until resumed.
            if !Task.isCancelled && returningRequest.owns(lease) { visibleSectionPopulated = false }
        }
        try await settle { returningRequest.loading }
        for _ in 0..<100 { if await delayedCancellation.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        leavingSection.cancel()
        let returningLease = returningRequest.begin(replacing: true)
        try require(returningLease != nil && returningRequest.begin() == nil, "Return could not replace a cancelled load or allowed duplicate pagination")
        await delayedCancellation.finish(); await leavingSection.value
        try require(returningRequest.loading && returningRequest.owns(returningLease!), "Old cancellation cleared the new section's loading ownership")
        visibleSectionPopulated = true; returningRequest.finish(returningLease!)
        try require(visibleSectionPopulated && !returningRequest.loading, "Returning section did not finish without another click")
        print("PASS rapid return supersedes delayed cancellation without clearing the newer load or duplicating pagination")

        await pages.loadInitial(key: "A") { try pageFixture($0) }
        await pages.loadInitial(key: "B") { _ in
            let partialPage = try JSONDecoder().decode(MLPageData.self, from: Data("{\"Page\":{\"media\":[{\"id\":99}]}}".utf8))
            return MLResult(value: partialPage, cachedAt: nil, isPartial: true)
        }
        let returnToA = Task { await pages.loadInitial(key: "A") { page in
            try await Task.sleep(for: .milliseconds(100)); return try pageFixture(page)
        } }
        try await Task.sleep(for: .milliseconds(20))
        try require(pages.page == 0 && pages.data.media == nil, "Returning from partial B preserved B entries as A")
        await returnToA.value
        print("PASS partial results never masquerade as a previous query during refresh")

        let hydrationRace = MLPageStore()
        await hydrationRace.loadInitial(key: "old") { try pageFixture($0) }
        let delayedHydration = Task {
            await hydrationRace.hydratePreparedPages(count: 2) { page in
                try await Task.sleep(for: .milliseconds(100))
                return try pageFixture(page)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await hydrationRace.loadInitial(key: "replacement") { try pageFixture($0) }
        await delayedHydration.value
        try require(hydrationRace.page == 1, "Obsolete prepared hydration appended to a replacement query")
        let expandedLibrary = MLPageStore()
        func fullPage(_ page: Int) throws -> MLResult<MLPageData> {
            let items = ((page - 1) * 40..<(page * 40)).map { "{\"id\":\($0)}" }.joined(separator: ",")
            let value = try JSONDecoder().decode(MLPageData.self, from: Data("{\"Page\":{\"media\":[\(items)],\"pageInfo\":{\"hasNextPage\":true}}}".utf8))
            return MLResult(value: value, cachedAt: nil)
        }
        await expandedLibrary.loadInitial(key: "expanded") { try fullPage($0) }
        await expandedLibrary.hydratePreparedPages(count: 12) { try fullPage($0) }
        try require(expandedLibrary.data.media?.count == 480 && expandedLibrary.data.media?.first??.id == 0 && !expandedLibrary.earlierPagesReleased,
                    "Opt-in hydration discarded the beginning of a prepared library")
        print("PASS prepared hydration rejects obsolete reads and retains all prepared entries beyond the default window")

        // Opt-in launch preparation uses the same cached queries as navigation.
        NoNetworkProtocol.unauthorized = false
        NoNetworkProtocol.requests = 0
        let readyPage = "{\"mediaList\":[],\"media\":[],\"activities\":[],\"pageInfo\":{\"hasNextPage\":false}}"
        let firstPage = readyPage.replacingOccurrences(of: "false", with: "true")
        let aliases = (0..<4).map { "\"prepared\($0)\":\(firstPage)" }.joined(separator: ",")
        NoNetworkProtocol.responseBody = "{\"data\":{\"Viewer\":{\"id\":7,\"name\":\"Fixture\"},\"watching\":{\"mediaList\":[]},\"reading\":{\"mediaList\":[]},\"discovery\":{\"media\":[]},\"Page\":\(readyPage),\(aliases)}}"

        let preparationDefaults = MemoryDefaults()
        preparationDefaults.set(true, forKey: MaoListModule.preferenceKey)
        preparationDefaults.set(true, forKey: MaoListModule.preparationPreferenceKey)
        let preparedCredentials = MemoryCredentials(MLCredentials(accessToken: "fixture-token", expiresAt: Date().addingTimeInterval(3600), userID: 7, userName: "Fixture"))
        let prepared = MaoListModule(defaults: preparationDefaults, supported: true) {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NoNetworkProtocol.self]
            return MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), cacheBase: cacheRoot.appendingPathComponent("preparation"), minimumSpacing: 0), keychain: preparedCredentials)
        }
        try await settle { prepared.runtime?.preparing == false }
        try require(prepared.runtime?.preparationStatus == "Preparation finished." && NoNetworkProtocol.requests == 21,
                    "Launch preparation coverage failed: \(prepared.runtime?.preparationStatus ?? "nil"), \(NoNetworkProtocol.requests) requests, \(MLPreparationEntry.all.count) entries")
        let preparedLoads = await preparedCredentials.loads
        try require(preparedLoads == 1, "Preparation loaded credentials more than once")
        let preparedRepository = prepared.runtime!.repository
        _ = try await preparedRepository.library(userID: 7, type: .anime, status: nil, page: 1)
        _ = try await preparedRepository.library(userID: 7, type: .manga, status: .completed, page: 1)
        _ = try await preparedRepository.search(.discovery(type: .anime, sort: "TRENDING_DESC"), page: 1)
        _ = try await preparedRepository.feed(following: true, page: 1)
        for entry in MLPreparationEntry.all {
            switch entry.kind {
            case .library(let type, let status):
                try require(prepared.runtime?.preparedPageCount(type: type, status: status) == 2, "Preparation missed a remaining library page")
                _ = try await preparedRepository.library(userID: 7, type: type, status: status, page: 2)
            case .discovery(let filters): _ = try await preparedRepository.search(filters, page: 1)
            case .activity(let following): _ = try await preparedRepository.feed(following: following, page: 1)
            }
        }
        let hydrated = MLPageStore()
        await hydrated.loadInitial(key: "prepared") { try await preparedRepository.library(userID: 7, type: .anime, status: nil, page: $0) }
        await hydrated.hydratePreparedPages(count: 2) { try await preparedRepository.cachedLibrary(userID: 7, type: .anime, status: nil, page: $0) }
        try require(hydrated.page == 2 && !hydrated.hasNext, "Opening a prepared library did not hydrate all cached pages")
        try require(NoNetworkProtocol.requests == 21, "Prepared navigation sent duplicate requests")
        prepared.runtime?.beginRestoreConnection()
        let foregroundLoads = await preparedCredentials.loads
        try require(foregroundLoads == 1, "Foreground opening re-read prepared credentials")
        let preparedAccountRoot = cacheRoot.appendingPathComponent("preparation/accounts/7")
        func agePreparedCache(_ seconds: Double) throws {
            for file in try FileManager.default.contentsOfDirectory(at: preparedAccountRoot, includingPropertiesForKeys: nil) where !file.lastPathComponent.hasPrefix(".") {
                let entry = try JSONDecoder().decode(MLDiskCache.Entry.self, from: Data(contentsOf: file))
                let aged = MLDiskCache.Entry(storedAt: Date().addingTimeInterval(-seconds), data: entry.data, invalidated: entry.invalidated, prepared: entry.prepared)
                try JSONEncoder().encode(aged).write(to: file, options: .atomic)
            }
        }
        try agePreparedCache(600)
        let olderPrepared = try await preparedRepository.library(userID: 7, type: .anime, status: nil, page: 1)
        let olderCached = try await preparedRepository.cachedLibrary(userID: 7, type: .anime, status: nil, page: 2)
        try require(olderPrepared.isStale && olderCached?.isStale == true && NoNetworkProtocol.requests == 21,
                    "Prepared snapshots lost reuse after five minutes or hid their age")
        try agePreparedCache(1900)
        let expiredPrepared = try await preparedRepository.cachedLibrary(userID: 7, type: .anime, status: nil, page: 2)
        try require(expiredPrepared == nil && NoNetworkProtocol.requests == 21, "Prepared cache exceeded30minutes or cache-only lookup started networking")
        print("PASS prepared snapshots retain bounded warm reuse, expose age and expire without networking")
        let previousEpoch = await preparedRepository.client.preparationEpoch()
        await preparedRepository.client.authorize(token: "replacement-fixture", accountID: 8)
        var rejectedOldAccount = false
        do {
            try await preparedRepository.client.cachePrepared(MLRepository.libraryQuery, variables: [:], value: MLPageData(Page: MLPage()), epoch: previousEpoch)
        } catch is CancellationError { rejectedOldAccount = true }
        try require(rejectedOldAccount, "Preparation seeded an old account response into a replacement account")
        prepared.setEnabled(false)
        try require(prepared.runtime == nil, "Prepared runtime survived disable")
        NoNetworkProtocol.responseBody = nil; NoNetworkProtocol.requests = 0
        print("PASS opt-in startup prepares every main section/status once and foreground navigation reuses its cache")

        let noninteractiveDefaults = MemoryDefaults()
        noninteractiveDefaults.set(true, forKey: MaoListModule.preferenceKey)
        noninteractiveDefaults.set(true, forKey: MaoListModule.preparationPreferenceKey)
        let deferredCredentials = WaitingCredentials()
        let deferred = MaoListModule(defaults: noninteractiveDefaults, supported: true) {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NoNetworkProtocol.self]
            return MLRuntime(client: MLGraphQLClient(session: URLSession(configuration: config), cacheBase: cacheRoot.appendingPathComponent("deferred"), minimumSpacing: 0), keychain: deferredCredentials)
        }
        try await settle { deferred.runtime?.preparing == false }
        let silentLoads = await deferredCredentials.loads
        try require(silentLoads == 0 && NoNetworkProtocol.requests == 0, "Background preparation used an interactive credential read")
        deferred.runtime?.beginRestoreConnection(); deferred.runtime?.beginRestoreConnection()
        for _ in 0..<100 { if await deferredCredentials.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let interactiveLoads = await deferredCredentials.loads
        try require(interactiveLoads == 1, "Foreground fallback duplicated credential prompts")
        await deferredCredentials.finish()
        deferred.setEnabled(false)
        print("PASS locked credentials defer to one foreground read and old-account preparation cannot seed a replacement account")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        ArtworkProtocol.data = bitmap.representation(using: .png, properties: [:])!
        let imageConfig = URLSessionConfiguration.ephemeral
        imageConfig.protocolClasses = [ArtworkProtocol.self]
        let artwork = MLImageLoader(session: URLSession(configuration: imageConfig), cacheBase: cacheRoot.appendingPathComponent("image-fixture"))
        let source = URL(string: "https://s4.anilist.co/fixture-cover.png")!
        let small = Task { await artwork.image(source, pixels: 160) }
        let large = Task { await artwork.image(source, pixels: 320) }
        let firstImage = await small.value, secondImage = await large.value
        try require(firstImage != nil && secondImage != nil && ArtworkProtocol.requests == 1,
                    "Different artwork sizes did not share one source download")
        let another = URL(string: "https://s4.anilist.co/fixture-other.png")!
        let cancelledImage = Task { await artwork.image(another, pixels: 160) }
        let survivingImage = Task { await artwork.image(another, pixels: 320) }
        try await Task.sleep(for: .milliseconds(30)); cancelledImage.cancel()
        let cancelledResult = await cancelledImage.value, survivingResult = await survivingImage.value
        try require(cancelledResult == nil && survivingResult != nil && ArtworkProtocol.requests == 2,
                    "Cancelling one artwork size broke another consumer or duplicated bytes")
        let nearbySize = await artwork.image(source, pixels: 159)
        try require(nearbySize === firstImage && ArtworkProtocol.requests == 2,
                    "Nearby layout sizes repeated the same artwork decode/download")
        let displayedArtwork = MLArtworkState()
        await displayedArtwork.load(source, pixels: 160, loader: artwork)
        let obsoleteSource = URL(string: "https://s4.anilist.co/obsolete-cover.png")!
        let obsoleteArtwork = Task { await displayedArtwork.load(obsoleteSource, pixels: 160, loader: artwork) }
        try await Task.sleep(for: .milliseconds(30))
        try require(displayedArtwork.source == obsoleteSource && displayedArtwork.image == nil,
                    "Changing artwork URLs kept displaying the previous cover")
        await displayedArtwork.load(source, pixels: 160, loader: artwork)
        obsoleteArtwork.cancel(); await obsoleteArtwork.value
        try require(displayedArtwork.source == source && displayedArtwork.image != nil && ArtworkProtocol.requests == 3,
                    "An obsolete cancelled artwork task cleared the newer cover")
        print("PASS artwork URL replacement, cancelled completion isolation and bucketed decode reuse")
        artwork.stop()
        await displayedArtwork.load(source, pixels: 800, loader: artwork)
        try require(displayedArtwork.image != nil, "A failed same-URL resize discarded an already displayed cover")
        let afterStop = await artwork.image(URL(string: "https://s4.anilist.co/stopped.png"), pixels: 160)
        try require(afterStop == nil && ArtworkProtocol.requests == 3, "Stopped artwork loader sent a request")
        print("PASS artwork sizes share one download, independent cancellation and no networking after stop")
        let repairRoot = cacheRoot.appendingPathComponent("artwork-repair")
        let repairDisk = MLDiskCache(namespace: "artwork", limit: 96_000_000, base: repairRoot)
        let brokenURL = URL(string: "https://s4.anilist.co/damaged-cover.png")!
        await repairDisk.write(Data("not an image".utf8), key: brokenURL.absoluteString)
        let repairLoader = MLImageLoader(session: URLSession(configuration: imageConfig), cacheBase: repairRoot)
        let beforeRepair = ArtworkProtocol.requests
        let repairedSmall = Task { await repairLoader.image(brokenURL, pixels: 160) }
        let repairedLarge = Task { await repairLoader.image(brokenURL, pixels: 320) }
        let repairedOne = await repairedSmall.value, repairedTwo = await repairedLarge.value
        try require(repairedOne != nil && repairedTwo != nil && ArtworkProtocol.requests == beforeRepair + 1, "Damaged cached artwork did not repair through one shared request")
        repairLoader.clear()
        let repairedDiskImage = await repairLoader.image(brokenURL, pixels: 160)
        try require(repairedDiskImage != nil && ArtworkProtocol.requests == beforeRepair + 1, "Repaired artwork was not reusable from disk")
        let invalidURL = URL(string: "https://s4.anilist.co/invalid-response.png")!
        let validArtwork = ArtworkProtocol.data
        ArtworkProtocol.data = Data("<html>temporary server error</html>".utf8)
        let invalidImage = await repairLoader.image(invalidURL, pixels: 160)
        let invalidCached = await repairDisk.read(invalidURL.absoluteString)
        try require(invalidImage == nil && invalidCached == nil && ArtworkProtocol.requests == beforeRepair + 2, "Invalid network artwork was cached or retried in a loop")
        ArtworkProtocol.data = validArtwork
        let laterValidImage = await repairLoader.image(invalidURL, pixels: 160)
        try require(laterValidImage != nil && ArtworkProtocol.requests == beforeRepair + 3, "Later valid artwork could not recover from an invalid response")
        repairLoader.stop()
        print("PASS damaged artwork repair, shared consumers, healthy disk reuse and invalid-response cache rejection")
        print("MaoList lifecycle checks passed")
    }
}
