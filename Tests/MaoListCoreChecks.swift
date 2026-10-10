import Foundation

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var responseBody = Data()
    static var statusCode = 200
    static var headers: [String: String] = [:]
    static var requests = 0
    static var lastRequest: URLRequest?
    static var lastBody = Data()
    static var delay: TimeInterval = 0
    private var responseWork: DispatchWorkItem?
    static func configure(_ body: String, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        responseBody = Data(body.utf8); statusCode = status; self.headers = headers; requests = 0; lastRequest = nil
        lastBody = Data()
        self.delay = delay
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.responseBody; let status = Self.statusCode; let headers = Self.headers; let delay = Self.delay
        Self.requests += 1; Self.lastRequest = request
        Self.lastBody = Data()
        if let body = request.httpBody { Self.lastBody = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                Self.lastBody.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body); self.client?.urlProtocolDidFinishLoading(self)
        }
        responseWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { responseWork?.cancel() }
}

@main private struct MaoListCoreChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "MaoListChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func expectError(_ expected: MLError, _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw NSError(domain: "MaoListChecks", code: 2) }
        catch let error as MLError { try require(error == expected, "Expected \(expected), received \(error)") }
    }
    static func makeClient(_ root: URL) -> MLGraphQLClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return MLGraphQLClient(session: URLSession(configuration: configuration), cacheBase: root, minimumSpacing: 0)
    }
    static func lastVariables() throws -> [String: Any] {
        let request = try JSONSerialization.jsonObject(with: FixtureProtocol.lastBody) as? [String: Any]
        guard let variables = request?["variables"] as? [String: Any] else { throw MLError.invalidResponse }
        return variables
    }
    static func main() async throws {
        let callbackBase = "nokocord-maolist://oauth#state=fixture-state&access_token=fixture-token&token_type=Bearer"
        let authorization = try MLAuthorization(callback: URL(string: callbackBase + "&expires_in=3600")!, expectedState: "fixture-state")
        try require(authorization.accessToken == "fixture-token" && authorization.lifetime == 3600, "Valid implicit callback rejected")
        try require(!String(describing: authorization).contains("fixture-token"), "Authorization description exposes its token")
        for callback in [
            callbackBase.replacingOccurrences(of: "nokocord-maolist", with: "https"),
            callbackBase.replacingOccurrences(of: "://oauth", with: "://other"),
            callbackBase.replacingOccurrences(of: "://oauth", with: "://oauth/other"),
            callbackBase.replacingOccurrences(of: "://oauth", with: "://user@oauth"),
            callbackBase.replacingOccurrences(of: "://oauth", with: "://oauth:443"),
            callbackBase.replacingOccurrences(of: "state=fixture-state", with: "state=wrong"),
            callbackBase + "&state=fixture-state",
            callbackBase + "&access_token=another-token",
            callbackBase + "&expires_in=nan",
            callbackBase + "&expires_in=inf",
            callbackBase + "&expires_in=0",
            callbackBase + "&expires_in=-1",
            callbackBase + "&error=access_denied",
            callbackBase.replacingOccurrences(of: "fixture-token", with: ""),
            callbackBase.replacingOccurrences(of: "fixture-token", with: "fixture%20token")
        ] {
            try await expectError(.authentication) { _ = try MLAuthorization(callback: URL(string: callback)!, expectedState: "fixture-state") }
        }
        print("PASS implicit callback state, origin, duplicate parameters, expiry and token redaction")
        for dark in [false, true] {
            let background = MLRGB(hex: dark ? "141817" : "F6F8F6")!
            for hex in ["FFFFFF", "000000", "FFFF00", "123456", "FF00FF", "72CDB4", "176D59"] {
                let readable = MLRGB(hex: hex)!.readable(on: background, dark: dark)
                try require(readable.contrast(with: background) >= 4.5, "Custom accent has unreadable contrast")
            }
        }
        try require(MLRGB(hex: "not-a-color") == nil, "Malformed color accepted")
        print("PASS accent contrast in light/dark appearances and invalid color fallback")
        let window = MLPageWindow.merge((1...390).map { MLMedia(id: $0) }, (380...420).map { MLMedia(id: $0) })
        try require(window.released && window.items.count == 400 && window.items.first?.id == 21 && window.items.last?.id == 420, "Paged collection grew past its limit or retained duplicates")
        let connection = MLPageWindow.merge(MLConnection(nodes: [MLMedia(id: 1), nil], pageInfo: nil), MLConnection(nodes: [MLMedia(id: 1), MLMedia(id: 2)], pageInfo: MLPageInfo(currentPage: 2, hasNextPage: false)))
        try require(connection.connection?.items.map(\.id) == [1, 2] && connection.connection?.pageInfo?.currentPage == 2, "Connection merge lost its latest cursor or duplicated entries")
        print("PASS bounded collection windows, nullable nodes and duplicate removal")
        for date in [MLFuzzyDate(), MLFuzzyDate(year: 1, month: 1, day: 1), MLFuzzyDate(year: 9999, month: 12, day: 31), MLFuzzyDate(month: 2, day: 29), MLFuzzyDate(year: 2000, month: 2, day: 29), MLFuzzyDate(year: 2024, month: 2, day: 29), MLFuzzyDate(day: 31)] {
            try require(date.isValid, "Valid or partial date rejected")
        }
        for date in [MLFuzzyDate(year: 0), MLFuzzyDate(year: 10000), MLFuzzyDate(month: 0), MLFuzzyDate(month: 13), MLFuzzyDate(day: 0), MLFuzzyDate(day: 32), MLFuzzyDate(month: 2, day: 30), MLFuzzyDate(month: 4, day: 31), MLFuzzyDate(year: 1900, month: 2, day: 29), MLFuzzyDate(year: 2023, month: 2, day: 29)] {
            try require(!date.isValid, "Impossible date accepted")
        }
        print("PASS partial dates, Gregorian leap years and impossible day rejection")
        let embeddedBio = MLReadableText("A **readable** bio.\n\n\nimg220(https://example.com/cover_(edition).png)\n\u{3164}img(https://example.com/other.png)\n[An ordinary link](https://anilist.co)")
        try require(embeddedBio.hasUnsupportedContent && embeddedBio.text == "A **readable** bio.\n\n[An ordinary link](https://anilist.co)", "AniList embeds leaked resource URLs or lost ordinary Markdown")
        let embedOnly = MLReadableText("\u{3164}img220(https://example.com/a)\n![cover](https://example.com/b)\nyoutube(https://example.com/c)")
        try require(embedOnly.hasUnsupportedContent && embedOnly.text.isEmpty, "Embed-only bio retained unusable markup")
        let spoiler = MLReadableText("Before ~!secret\nsecond line!~ after")
        try require(spoiler.hasUnsupportedContent && spoiler.text == "Before [Spoiler hidden] after", "Multiline spoiler leaked its contents")
        let incompleteSpoiler = MLReadableText("Before ~!secret\nsecond line")
        try require(!incompleteSpoiler.text.contains("secret"), "Unclosed spoiler leaked its contents")
        try require(MLReadableText("Hello<br>world &amp; friends").text == "Hello\nworld & friends", "HTML line breaks or entities lost")
        print("PASS embedded resource omission, ordinary Markdown preservation and multiline spoiler hiding")
        for kind in [MLPostTextKind.activity, .reply] {
            try require(!kind.accepts("     ") && !kind.accepts(String(repeating: "a", count: kind.limits.lowerBound - 1)) && !kind.accepts(String(repeating: "a", count: kind.limits.upperBound + 1)), "Out-of-range social text accepted")
            try require(kind.accepts(String(repeating: "a", count: kind.limits.lowerBound)) && kind.accepts(String(repeating: "a", count: kind.limits.upperBound)), "Valid boundary social text rejected")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MaoListChecks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeClient(root); let repository = MLRepository(client: client)
        FixtureProtocol.configure("{}")
        try await expectError(.rejected) { try await repository.postActivity("tiny") }
        try await expectError(.rejected) { try await repository.postReply("a", activityID: 1) }
        try require(FixtureProtocol.requests == 0, "Invalid social text sent a network request")
        print("PASS documented social text bounds and zero requests for invalid posts")
        let fixture = "{\"data\":{\"Page\":{\"pageInfo\":{\"currentPage\":1,\"hasNextPage\":true},\"media\":[null,{\"id\":1,\"title\":{\"userPreferred\":\"A title\"},\"type\":\"ANIME\"}]}}}"
        FixtureProtocol.configure(fixture)
        let result = try await repository.search(MLSearchFilters(), page: 1)
        try require(result.value.Page?.media?.compactMap { $0 }.count == 1, "Nullable media decoding failed")
        _ = try await repository.search(MLSearchFilters(), page: 1)
        try require(FixtureProtocol.requests == 1, "Fresh cache did not avoid duplicate networking")
        FixtureProtocol.configure("{}", status: 503)
        let stale = try await repository.search(MLSearchFilters(), page: 1, refresh: true)
        try require(stale.isStale, "Offline fallback lost stale indication")
        print("PASS nullable decoding, pagination, fresh cache, offline stale fallback")

        let damagedRoot = root.appendingPathComponent("damaged-cache")
        let damagedClient = makeClient(damagedRoot), damagedDisk = MLDiskCache(namespace: "public", limit: 16_000_000, base: damagedRoot)
        let damagedRepository = MLRepository(client: damagedClient)
        FixtureProtocol.configure(fixture)
        _ = try await damagedRepository.search(MLSearchFilters(), page: 1)
        let damagedKey = String(decoding: FixtureProtocol.lastBody, as: UTF8.self)
        await damagedDisk.write(Data("{\"data\":{\"Page\":\"obsolete schema\"}}".utf8), key: damagedKey)
        FixtureProtocol.configure(fixture)
        let repaired = try await damagedRepository.search(MLSearchFilters(), page: 1)
        try require(repaired.value.Page?.media?.compactMap { $0 }.first?.id == 1 && FixtureProtocol.requests == 1,
                    "A damaged fresh cache entry prevented network recovery")
        _ = try await damagedRepository.search(MLSearchFilters(), page: 1)
        try require(FixtureProtocol.requests == 1, "Recovered cache did not retain warm reuse")
        await damagedDisk.write(Data("{\"data\":{\"Page\":\"obsolete schema\"}}".utf8), key: damagedKey)
        FixtureProtocol.configure("{}", status: 503)
        try await expectError(.unavailable) { _ = try await damagedRepository.search(MLSearchFilters(), page: 1) }
        await damagedClient.stop()
        print("PASS damaged cache entries recover online without breaking warm reuse or masking network failures")

        let debounceClient = makeClient(root.appendingPathComponent("debounce"))
        let debounceRepository = MLRepository(client: debounceClient)
        FixtureProtocol.configure(fixture)
        _ = try await debounceRepository.search(MLSearchFilters(), page: 1)
        let warmStarted = ContinuousClock.now
        _ = try await debounceRepository.search(MLSearchFilters(), page: 1, notBefore: .now.advanced(by: .seconds(2)))
        let warmDuration = warmStarted.duration(to: .now)
        try require(warmDuration < .milliseconds(500) && FixtureProtocol.requests == 1, "Warm search waited for typing debounce or refetched")
        FixtureProtocol.configure(fixture)
        let typing = Task { try await debounceRepository.search(MLSearchFilters(), page: 2, notBefore: .now.advanced(by: .seconds(2))) }
        try await Task.sleep(for: .milliseconds(40)); typing.cancel()
        do { _ = try await typing.value; throw NSError(domain: "MaoListChecks", code: 5) }
        catch is CancellationError { }
        try require(FixtureProtocol.requests == 0, "Cancelled typing consumed an API request")
        _ = try await debounceRepository.search(MLSearchFilters(), page: 2)
        try require(FixtureProtocol.requests == 1, "Explicit search did not replace cancelled typing")
        FixtureProtocol.configure(fixture)
        let pendingSubmit = Task { try await debounceRepository.search(MLSearchFilters(), page: 3, notBefore: .now.advanced(by: .seconds(2))) }
        try await Task.sleep(for: .milliseconds(40))
        let submittedAt = ContinuousClock.now
        _ = try await debounceRepository.search(MLSearchFilters(), page: 3)
        _ = try await pendingSubmit.value
        try require(submittedAt.duration(to: .now) < .milliseconds(500) && FixtureProtocol.requests == 1,
                    "Submit did not expedite/deduplicate an already waiting typing request")
        await debounceClient.stop()
        print("PASS warm search bypasses typing debounce; cancelled input sends zero requests; explicit search proceeds immediately")


        let partialClient = makeClient(root.appendingPathComponent("partial"))
        let partialRepository = MLRepository(client: partialClient)
        FixtureProtocol.configure(fixture.dropLast() + ",\"errors\":[{\"status\":400}]}")
        let partial = try await partialRepository.search(MLSearchFilters(), page: 1)
        try require(partial.isPartial && !partial.isStale && partial.value.Page?.media?.compactMap { $0 }.count == 1, "Available partial query data lost its warning or content")
        let savedPartial = try await partialRepository.search(MLSearchFilters(), page: 1)
        try require(savedPartial.isPartial && FixtureProtocol.requests == 1, "Cached partial query lost its warning")
        FixtureProtocol.configure("{}", status: 503)
        let offlinePartial = try await partialRepository.search(MLSearchFilters(), page: 1, refresh: true)
        try require(offlinePartial.isPartial && offlinePartial.isStale, "Offline partial query lost a warning")
        await partialClient.authorize(token: "fixture-auth", accountID: 123)
        FixtureProtocol.configure("{\"data\":{\"Viewer\":\"malformed partial data\"},\"errors\":[{\"status\":401}]}")
        try await expectError(.authentication) { _ = try await partialRepository.viewer(refresh: true) }
        try await expectError(.authentication) { _ = try await partialRepository.viewer(refresh: true) }
        try require(FixtureProtocol.requests == 1, "Malformed expired-token response retried authentication")
        await partialClient.stop()
        print("PASS partial query warnings survive cache/offline and malformed data cannot conceal expired authorization")

        let sharedClient = makeClient(root.appendingPathComponent("concurrency"))
        let sharedRepository = MLRepository(client: sharedClient)
        FixtureProtocol.configure(fixture, delay: 0.5)
        let first = Task { try await sharedRepository.search(MLSearchFilters(), page: 1) }
        try await Task.sleep(for: .milliseconds(70))
        let second = Task { try await sharedRepository.search(MLSearchFilters(), page: 1) }
        try await Task.sleep(for: .milliseconds(70))
        first.cancel()
        _ = try await second.value
        do { _ = try await first.value; throw NSError(domain: "MaoListChecks", code: 3) }
        catch is CancellationError { }
        try require(FixtureProtocol.requests == 1, "Cancelling one consumer broke request deduplication")
        FixtureProtocol.configure(fixture, delay: 0.5)
        let cancelled = Task { try await sharedRepository.search(MLSearchFilters(), page: 2) }
        try await Task.sleep(for: .milliseconds(70)); cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "MaoListChecks", code: 4) }
        catch is CancellationError { }
        _ = try await sharedRepository.search(MLSearchFilters(), page: 2)
        try require(FixtureProtocol.requests == 2, "Final cancellation retained an obsolete shared request")
        await sharedClient.stop()
        print("PASS shared request cancellation, deduplication and replacement")

        let queueConfig = URLSessionConfiguration.ephemeral
        queueConfig.protocolClasses = [FixtureProtocol.self]
        let queueClient = MLGraphQLClient(session: URLSession(configuration: queueConfig), cacheBase: root.appendingPathComponent("queue"), minimumSpacing: 0.1)
        let queueRepository = MLRepository(client: queueClient)
        FixtureProtocol.configure(fixture)
        let obsolete = (1...8).map { page in Task { try await queueRepository.search(MLSearchFilters(), page: page) } }
        try await Task.sleep(for: .milliseconds(30))
        obsolete.forEach { $0.cancel() }
        for task in obsolete { _ = try? await task.value }
        let replacementStarted = Date()
        _ = try await queueRepository.search(MLSearchFilters(), page: 99)
        try require(Date().timeIntervalSince(replacementStarted) < 0.4, "Cancelled requests left reserved time slots delaying the visible page")
        await queueClient.stop()
        print("PASS obsolete requests do not delay the next visible page")

        let disk = MLDiskCache(namespace: "disk", limit: 1600, base: root)
        await disk.write(Data(repeating: 7, count: 800), key: "old")
        await disk.write(Data(repeating: 8, count: 800), key: "new")
        let evicted = await disk.read("old"), kept = await disk.read("new")
        try require(evicted == nil && kept != nil, "Disk cache exceeded its bounded size")
        await disk.invalidate()
        let invalidated = await disk.read("new")
        try require(invalidated?.invalidated == true, "Mutation invalidation lost offline cache data")
        await disk.retire(clear: true)
        await disk.write(Data([1]), key: "late")
        let late = await disk.read("late")
        try require(late == nil, "Retired cache accepted a late account write")
        print("PASS disk eviction, offline-preserving invalidation and retired writes")

        await client.authorize(token: "fixture-token", accountID: 7)
        FixtureProtocol.configure(fixture)
        _ = try await repository.search(MLSearchFilters(), page: 1)
        try require(FixtureProtocol.requests == 1, "Private query reused public cache")
        try require(FixtureProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Missing auth header")
        try require(!(FixtureProtocol.lastRequest?.url?.absoluteString.contains("fixture-token") ?? true), "Token leaked into URL")
        print("PASS account/public cache separation and header-only authorization")

        let replacementClient = makeClient(root.appendingPathComponent("account-replacement"))
        let replacementRepository = MLRepository(client: replacementClient)
        await replacementClient.authorize(token: "old-fixture-token", accountID: 17)
        FixtureProtocol.configure(fixture)
        _ = try await replacementRepository.search(MLSearchFilters(), page: 1)
        FixtureProtocol.configure("{\"data\":null,\"errors\":[{\"status\":401}]}", delay: 0.5)
        let oldAccountRead = Task { try await replacementRepository.search(MLSearchFilters(), page: 2) }
        try await Task.sleep(for: .milliseconds(70))
        try require(FixtureProtocol.requests == 1, "Account replacement fixture did not start its old request")
        await replacementClient.authorize(token: "new-fixture-token", accountID: 18)
        do { _ = try await oldAccountRead.value; throw MLError.invalidResponse }
        catch is CancellationError { }
        FixtureProtocol.configure(fixture)
        _ = try await replacementRepository.search(MLSearchFilters(), page: 1)
        try require(FixtureProtocol.requests == 1, "Replacement account reused the old account's cached page")
        try require(FixtureProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer new-fixture-token", "Obsolete failure removed replacement authorization")
        _ = try await replacementRepository.search(MLSearchFilters(), page: 1)
        try require(FixtureProtocol.requests == 1, "Replacement account failed to reuse its own warm page")
        await replacementClient.stop()
        print("PASS replacing an account cancels old reads, isolates cached pages and preserves the new authorization")

        FixtureProtocol.configure("{\"data\":{\"Viewer\":{\"id\":7,\"name\":\"Fixture\",\"avatar\":null,\"unreadNotificationCount\":0,\"mediaListOptions\":{\"scoreFormat\":\"POINT_3\",\"animeList\":{\"customLists\":[],\"advancedScoring\":null},\"mangaList\":null},\"statistics\":{\"anime\":{\"count\":0,\"statuses\":[]},\"manga\":null}}}}")
        let viewer = try await repository.viewer(refresh: true).value.Viewer
        try require(viewer?.id == 7 && viewer?.mediaListOptions?.scoreFormat == "POINT_3", "Viewer account response failed to decode")
        let viewerRequest = try JSONSerialization.jsonObject(with: FixtureProtocol.lastBody) as? [String: Any]
        let viewerQuery = viewerRequest?["query"] as? String ?? ""
        var depth = 0
        for character in viewerQuery {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            try require(depth >= 0, "Viewer query closed a selection before opening it")
        }
        try require(!viewerQuery.isEmpty && depth == 0, "Viewer query has an unterminated selection and cannot authenticate")
        print("PASS complete Viewer request and nullable account preferences")
        FixtureProtocol.configure("{\"data\":{\"Viewer\":{\"id\":7},\"watching\":{\"mediaList\":[{\"id\":9,\"media\":{\"id\":1}}]},\"reading\":{\"mediaList\":[]},\"discovery\":{\"media\":[{\"id\":2}]}}}")
        let home = try await repository.home(userID: 7)
        try require(home.value.watching?.mediaList?.compactMap({ $0 }).first?.id == 9 && home.value.discovery?.media?.compactMap({ $0 }).first?.id == 2 && FixtureProtocol.requests == 1, "Combined Home lost its named sections or sent multiple requests")
        _ = try await repository.home(userID: 7)
        try require(FixtureProtocol.requests == 1, "Combined Home skipped its fresh account cache")
        FixtureProtocol.configure("{\"data\":{\"Viewer\":{\"id\":7}}}")
        try await expectError(.invalidResponse) { _ = try await repository.home(userID: 7, refresh: true) }
        print("PASS combined Home decoding, one request, cache reuse and missing-section rejection")

        FixtureProtocol.configure("{\"data\":{\"MediaList\":{\"id\":9,\"score\":8.2}}}")
        let accountScore = try await repository.entryScore(9)
        let scoreRequest = try JSONSerialization.jsonObject(with: FixtureProtocol.lastBody) as? [String: Any]
        let scoreQuery = scoreRequest?["query"] as? String ?? ""
        try require(accountScore.value == 8.2 && !scoreQuery.contains("format:") && !MLRepository.listState.contains("score(format:") && !MLRepository.libraryItem.contains("score(format:"), "Personal scores were forced into a different scoring system")
        try require(MLScoreFormat.hundred.label(0) == "0 / 100" && MLScoreFormat.ten.label(0) == "0 / 10", "Whole-number score labels use the wrong scale")
        try require(MLScoreFormat.tenDecimal.label(8.2) == "8.2 / 10" && MLScoreFormat.tenDecimal.label(0) == "0.0 / 10", "Decimal score labels lost precision or use the wrong scale")
        try require(MLScoreFormat.five.label(4) == "4 / 5 stars" && MLScoreFormat.three.label(3) == "🙂", "Star/reaction score labels lost their scoring system")
        print("PASS personal score reads and labels preserve 100-point, 10-point, decimal, star and reaction formats")

        FixtureProtocol.configure("{\"data\":{\"Page\":{\"pageInfo\":{\"currentPage\":1,\"hasNextPage\":false},\"mediaList\":[{\"id\":1,\"status\":\"CURRENT\",\"media\":{\"id\":1,\"type\":\"ANIME\",\"mediaListEntry\":{\"id\":1,\"status\":\"CURRENT\"}}},{\"id\":2,\"status\":\"COMPLETED\",\"media\":{\"id\":2,\"type\":\"ANIME\",\"mediaListEntry\":{\"id\":2,\"status\":\"COMPLETED\"}}}]}}}")
        let all = try await repository.library(userID: 7, type: .anime, status: nil, page: 1)
        let allVariables = try lastVariables()
        try require(allVariables["status"] == nil && Set(all.value.Page?.mediaList?.compactMap { $0?.media?.mediaListEntry?.status } ?? []) == [.current, .completed], "All library omitted a status or sent a status restriction")
        print("PASS All library omits status restriction and retains section identities")

        let entryJSON = "{\"id\":9,\"score\":8.2,\"progress\":4,\"notes\":\"Keep me\",\"advancedScores\":{\"Story\":81,\"Music\":72}}"
        let state = try JSONDecoder().decode(MLListState.self, from: Data(entryJSON.utf8))
        let scoredMedia = MLMedia(id: 1, type: .anime, mediaListEntry: state)
        FixtureProtocol.configure("{\"data\":{\"SaveMediaListEntry\":\(entryJSON)}}")
        _ = try await repository.incrementProgress(mediaID: 1, entryID: 9, progress: 5)
        let progressVariables = try lastVariables()
        try require(Set(progressVariables.keys) == ["media", "id", "progress"], "Quick progress overwrites unrelated entry fields")
        var scoredDraft = MLListDraft(media: scoredMedia)
        scoredDraft.start = MLFuzzyDate(month: 2, day: 30)
        let requestsBeforeInvalidDate = FixtureProtocol.requests
        try await expectError(.rejected) { _ = try await repository.saveList(scoredDraft) }
        try require(FixtureProtocol.requests == requestsBeforeInvalidDate, "Invalid date sent a mutation request")
        scoredDraft.start = MLFuzzyDate()
        _ = try await repository.saveList(scoredDraft)
        let uneditedVariables = try lastVariables()
        try require(uneditedVariables["advanced"] == nil, "Unedited advanced dimensions were rewritten")
        try require(uneditedVariables["score"] == nil && uneditedVariables["scoreValue"] == nil, "Saving other fields rewrote an unchanged personal score")
        scoredDraft.displayedScore = 8.3
        scoredDraft.advancedScores["Story"] = 91
        scoredDraft.editedAdvancedScores = [scoredDraft.advancedScores["Story"]!, scoredDraft.advancedScores["Music"]!]
        _ = try await repository.saveList(scoredDraft)
        let scoredVariables = try lastVariables()
        try require(scoredVariables["score"] == nil && scoredVariables["scoreValue"] as? Double == 8.3, "Account score scale was not preserved")
        try require(scoredVariables["advanced"] as? [Double] == [91, 72], "Editing one dimension lost another score or its order")
        print("PASS progress-only mutation, unchanged dimensions and account score scale")

        let options = MLListOptions(scoreFormat: "POINT_10_DECIMAL", animeList: MLTypeListOptions(customLists: ["Favorites"], advancedScoring: ["Story", "Music"], advancedScoringEnabled: true, sectionOrder: ["CURRENT", "COMPLETED"]), mangaList: MLTypeListOptions(customLists: ["Reading group"]))
        var preferences = MLListPreferencesDraft(options)
        preferences.anime.customLists?.append("Watch together")
        FixtureProtocol.configure("{\"data\":{\"UpdateUser\":{\"id\":7,\"mediaListOptions\":{\"scoreFormat\":\"POINT_10_DECIMAL\",\"animeList\":{\"customLists\":[\"Favorites\",\"Watch together\"]}}}}}")
        _ = try await repository.saveListPreferences(preferences)
        let preferenceVariables = try lastVariables()
        let animeVariables = preferenceVariables["anime"] as? [String: Any]
        try require(Set(preferenceVariables.keys) == ["anime"] && animeVariables?.count == 1 && animeVariables?["customLists"] as? [String] == ["Favorites", "Watch together"], "Preference edit rewrote unrelated account settings")
        preferences.anime.customLists = ["Favorites", " favorites "]
        try await expectError(.rejected) { _ = try await repository.saveListPreferences(preferences) }
        FixtureProtocol.configure("{\"data\":{\"DeleteCustomList\":{\"deleted\":false}}}")
        try await expectError(.rejected) { try await repository.deleteCustomList("Favorites", type: .anime) }
        print("PASS minimal preference mutations, duplicate-name rejection and failed custom-list removal")

        FixtureProtocol.configure("{\"data\":{\"SaveMediaListEntry\":{\"id\":9}},\"errors\":[{\"status\":400}]}")
        let media = MLMedia(id: 1, type: .anime)
        try await expectError(.rejected) { _ = try await repository.saveList(MLListDraft(media: media)) }
        FixtureProtocol.configure("{\"data\":{\"SaveMediaListEntry\":null}}")
        try await expectError(.rejected) { _ = try await repository.saveList(MLListDraft(media: media)) }
        FixtureProtocol.configure("{\"data\":{\"DeleteMediaListEntry\":{\"deleted\":false}}}")
        try await expectError(.rejected) { try await repository.deleteList(9) }
        print("PASS failed, partial and null mutations never report success")

        FixtureProtocol.configure("{\"data\":null,\"errors\":[{\"status\":401}]}")
        try await expectError(.authentication) { _ = try await repository.viewer(refresh: true) }
        try await expectError(.authentication) { _ = try await repository.viewer(refresh: true) }
        try require(FixtureProtocol.requests == 1, "Invalid credentials were retried")
        print("PASS invalid token classification and repeat prevention")

        let rateClient = makeClient(root.appendingPathComponent("rate"))
        FixtureProtocol.configure("{}", status: 429, headers: ["Retry-After": "30"])
        do { _ = try await MLRepository(client: rateClient).search(MLSearchFilters(), page: 1); throw MLError.invalidResponse }
        catch MLError.rateLimited { }
        do { _ = try await MLRepository(client: rateClient).search(MLSearchFilters(), page: 1); throw MLError.invalidResponse }
        catch MLError.rateLimited { }
        try require(FixtureProtocol.requests == 1, "429 protection issued another request")
        await rateClient.stop()
        print("PASS 429 cooldown without retries")

        await client.stop()
        FixtureProtocol.configure(fixture)
        try await expectError(.stopped) { _ = try await repository.search(MLSearchFilters(), page: 2) }
        try require(FixtureProtocol.requests == 0, "Stopped client performed networking")
        print("PASS stopped module transport performs zero requests")
        print("MaoList core checks passed")
    }
}
