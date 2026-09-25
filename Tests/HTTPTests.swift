import XCTest
@testable import NokoCordCore

final class FixtureURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var calls = 0
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    static var requestURLs: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.calls += 1
        if let url = request.url { Self.requestURLs.append(url) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        let body = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class HTTPTests: XCTestCase {
    override func setUp() {
        FixtureURLProtocol.calls = 0; FixtureURLProtocol.status = 200
        FixtureURLProtocol.headers = [:]; FixtureURLProtocol.body = Data()
        FixtureURLProtocol.requestURLs = []
    }
    private func client() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return HTTPClient(configuration: config)
    }
    func testRateLimitPreventsImmediateRetry() async throws {
        FixtureURLProtocol.status = 429
        FixtureURLProtocol.headers = ["Retry-After": "120"]
        let http = client()
        for _ in 0..<2 {
            do { _ = try await http.request(URLRequest(url: URL(string: "https://fixture.invalid/test")!)); XCTFail("must rate limit") }
            catch TransportError.rateLimited(let delay) { XCTAssertGreaterThan(delay, 115) }
        }
        XCTAssertEqual(FixtureURLProtocol.calls, 1)
    }
    @MainActor
    func testTokenRefreshPreservesAccountCacheOwnership() async throws {
        FixtureURLProtocol.body = Data("""
        {"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer","scope":"identify guilds"}
        """.utf8)
        let auth = Authentication(http: client())
        let original = OAuthCredentials(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast,
                                        brokerOrigin: "https://fixture.invalid", accountID: "account-1")
        let refreshed = try await auth.refresh(original)
        XCTAssertEqual(refreshed.accountID, original.accountID)
        XCTAssertEqual(refreshed.brokerOrigin, original.brokerOrigin)
        XCTAssertEqual(refreshed.accessToken, "rotated-access")
        XCTAssertEqual(refreshed.refreshToken, "rotated-refresh")
        XCTAssertGreaterThan(refreshed.expiresAt, Date())
    }
    func testUnsafeRequestNeverTouchesNetwork() async throws {
        do { _ = try await client().request(URLRequest(url: URL(string: "http://fixture.invalid")!)); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? TransportError, .invalidConfiguration) }
        XCTAssertEqual(FixtureURLProtocol.calls, 0)
    }
    func testGuildPaginationRejectsOversizedPage() async throws {
        let page = (0..<201).map { ["id": String($0), "name": "Fixture"] }
        FixtureURLProtocol.body = try JSONSerialization.data(withJSONObject: page)
        do { _ = try await DiscordREST(http: client()).guilds(token: "fixture"); XCTFail("Oversized page must fail") }
        catch { XCTAssertEqual(error as? TransportError, .responseTooLarge) }
        XCTAssertEqual(FixtureURLProtocol.calls, 1)
    }

    func testRepeatedFullGuildPageTerminatesAndDeduplicates() async throws {
        let page = (0..<200).map { ["id": String($0), "name": "Fixture"] }
        FixtureURLProtocol.body = try JSONSerialization.data(withJSONObject: page)
        let guilds = try await DiscordREST(http: client()).guilds(token: "fixture")
        XCTAssertEqual(guilds.count, 200)
        XCTAssertEqual(Set(guilds.map(\.id)).count, 200)
        XCTAssertEqual(FixtureURLProtocol.calls, 2)
        let urls = FixtureURLProtocol.requestURLs
        XCTAssertEqual(urls.count, 2)
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(url.host, "discord.com")
            XCTAssertEqual(url.path, "/api/v10/users/@me/guilds")
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.filter { $0.name == "with_counts" }, [.init(name: "with_counts", value: "true")])
            XCTAssertEqual(query.filter { $0.name == "limit" }, [.init(name: "limit", value: "200")])
            XCTAssertEqual(query.first { $0.name == "after" }?.value, index == 0 ? nil : "199")
        }
    }
    func testUnauthorizedIsDistinctFromServerFailure() async throws {
        FixtureURLProtocol.status = 401
        do { _ = try await client().request(URLRequest(url: URL(string: "https://fixture.invalid")!)); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? TransportError, .unauthorized) }
    }
    func testOversizedDeclaredResponseRejected() async throws {
        FixtureURLProtocol.headers = ["Content-Length": "2097153"]
        do { _ = try await client().request(URLRequest(url: URL(string: "https://fixture.invalid")!)); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? TransportError, .responseTooLarge) }
    }
    func testRedirectIsNotFollowed() async {
        let delegate = NoRedirects()
        let request = URLRequest(url: URL(string: "https://other.invalid")!)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        delegate.urlSession(.shared, task: URLSession.shared.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected in XCTAssertNil(redirected) }
    }
    func testAccountCacheRoundTripAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AccountCache(directory: directory)
        let user = DiscordUser(id: "fixture", username: "Sample", globalName: nil, avatar: nil)
        try await cache.save(account: user, guilds: [])
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.account, user)
        try await cache.clear()
        let cleared = try await cache.load()
        XCTAssertNil(cleared)
    }
    func testCancelledCacheSaveDoesNotWriteAccountData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AccountCache(directory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.save(account: DiscordUser(id: "fixture", username: "Sample", globalName: nil, avatar: nil), guilds: [])
        }
        do { try await task.value; XCTFail("Cancelled writes must not persist") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await cache.load()
        XCTAssertNil(snapshot)
    }

}
