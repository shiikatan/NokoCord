import Foundation
import OSLog
import CryptoKit

enum MLValue: Encodable, Sendable {
    case string(String), int(Int), number(Double), bool(Bool), strings([String]), numbers([Double]), object([String: MLValue]), null
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .numbers(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MLResult<T: Sendable>: Sendable {
    let value: T
    let cachedAt: Date?
    var isPartial = false
    var isStale: Bool { cachedAt != nil }
    func map<U: Sendable>(_ transform: (T) -> U) -> MLResult<U> {
        MLResult<U>(value: transform(value), cachedAt: cachedAt, isPartial: isPartial)
    }
}

actor MLDiskCache {
    struct Entry: Codable { let storedAt: Date; let data: Data; var invalidated: Bool? = nil; var prepared: Bool? = nil }
    private let root: URL
    private let limit: Int
    private var writable = true
    init(namespace: String, limit: Int, base: URL? = nil) {
        root = (base ?? Self.base).appendingPathComponent(namespace, isDirectory: true)
        self.limit = limit
    }
    static var base: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.shiikatan.nokocord.maomao/MaoList", isDirectory: true)
    }
    private func file(_ key: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    func read(_ key: String) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file(key).path),
              (attributes[.size] as? Int ?? 0) <= 8_000_000,
              let data = try? Data(contentsOf: file(key)),
              var entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(entry.storedAt) < 7 * 86400 else { return nil }
        if let marker = try? String(contentsOf: root.appendingPathComponent(".invalidated"), encoding: .utf8),
           let timestamp = Double(marker), entry.storedAt.timeIntervalSince1970 <= timestamp { entry.invalidated = true }
        return entry
    }
    func write(_ data: Data, key: String, prepared: Bool = false) {
        guard writable, !Task.isCancelled, data.count < 8_000_000 else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoded = try JSONEncoder().encode(Entry(storedAt: Date(), data: data, prepared: prepared ? true : nil))
            try encoded.write(to: file(key), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
            trim()
        } catch { /* Cache failure must not prevent normal use. */ }
    }
    func clear() {
        try? FileManager.default.removeItem(at: root)
    }
    func remove(_ key: String, matching entry: Entry) {
        guard writable, !Task.isCancelled, read(key)?.storedAt == entry.storedAt else { return }
        try? FileManager.default.removeItem(at: file(key))
    }
    func invalidate() {
        guard writable, FileManager.default.fileExists(atPath: root.path) else { return }
        // One tiny marker preserves useful offline responses without rewriting
        // every cached page after each episode increment.
        try? Data(String(Date().timeIntervalSince1970).utf8).write(to: root.appendingPathComponent(".invalidated"), options: .atomic)
    }
    func retire(clear: Bool = false) {
        writable = false
        if clear { self.clear() }
    }
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for item in entries where total > limit || Date().timeIntervalSince(item.2) > 7 * 86400 {
            try? FileManager.default.removeItem(at: item.0)
            total -= item.1
        }
    }
    static func removeAccountData() throws {
        let privateRoot = base.appendingPathComponent("accounts", isDirectory: true)
        if FileManager.default.fileExists(atPath: privateRoot.path) { try FileManager.default.removeItem(at: privateRoot) }
    }
}

private final class MLTransportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func close() { lock.lock(); open = false; lock.unlock() }
    func check() throws {
        lock.lock(); let permitted = open; lock.unlock()
        if !permitted { throw CancellationError() }
    }
}

/// One cancellable transport per loaded module. No periodic refresh or retry loop.
actor MLGraphQLClient {
    private struct Request: Encodable { let query: String; let variables: [String: MLValue] }
    private struct Envelope<T: Decodable>: Decodable { let data: T?; let errors: [GraphError]? }
    private struct ErrorEnvelope: Decodable { let errors: [GraphError]? }
    private struct GraphError: Decodable { var status: Int? }
    private let session: URLSession
    private let publicCache: MLDiskCache
    private let cacheBase: URL?
    private let minimumSpacing: TimeInterval
    private var accountCache: MLDiskCache?
    private var token: String?
    private var stopped = false
    private var blockedUntil = Date.distantPast
    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
        let typingDelay: Task<Void, Never>?
        var consumers: Set<UUID>
    }
    private var inFlight: [String: Flight] = [:]
    private var cacheEpoch = 0
    private var authorizationEpoch = 0
    private let gate = MLTransportGate()
    private var lastStartedAt = Date.distantPast
    private var effectiveSpacing: TimeInterval = 2.1
    private var authenticationFailure: (@Sendable () -> Void)?

    init(session: URLSession? = nil, cacheBase: URL? = nil, minimumSpacing: TimeInterval? = nil) {
        self.cacheBase = cacheBase
        self.minimumSpacing = minimumSpacing ?? 0.75
        // Start conservatively until AniList advertises its current allowance.
        effectiveSpacing = minimumSpacing ?? 2.1
        publicCache = MLDiskCache(namespace: "public", limit: 16_000_000, base: cacheBase)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = session ?? URLSession(configuration: configuration)
    }
    func authorize(token: String?, accountID: Int?) async {
        guard !stopped else { return }
        cancelRequests()
        let oldCache = accountCache
        self.token = token
        accountCache = accountID.map { MLDiskCache(namespace: "accounts/\($0)", limit: 12_000_000, base: cacheBase) }
        cacheEpoch += 1
        authorizationEpoch += 1
        await oldCache?.retire()
    }
    func setAuthenticationFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        authenticationFailure = handler
    }
    nonisolated func close() {
        gate.close()
        session.invalidateAndCancel()
    }
    func resetAccount() async {
        cancelRequests()
        authorizationEpoch += 1
        cacheEpoch += 1
        token = nil
        let cache = accountCache
        accountCache = nil
        await cache?.retire(clear: true)
    }
    func stop() {
        close()
        stopped = true
        inFlight.values.forEach { $0.typingDelay?.cancel(); $0.task.cancel() }
        inFlight.removeAll()
        token = nil
        accountCache = nil
        authenticationFailure = nil
        session.invalidateAndCancel()
    }
    func cancelRequests() {
        inFlight.values.forEach { $0.typingDelay?.cancel(); $0.task.cancel() }
        inFlight.removeAll()
    }
    private func releaseFlight(_ key: String, id: UUID, consumer: UUID) {
        guard var flight = inFlight[key], flight.id == id else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flight.typingDelay?.cancel(); flight.task.cancel()
            inFlight[key] = nil
        } else { inFlight[key] = flight }
    }
    private func permitRequest() async throws {
        while true {
            try gate.check()
            try Task.checkCancellation()
            if blockedUntil > Date() { throw MLError.rateLimited(blockedUntil) }
            let wait = lastStartedAt.addingTimeInterval(effectiveSpacing).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)); continue }
            lastStartedAt = Date()
            return
        }
    }
    private func receiveRateHeaders(_ response: HTTPURLResponse) {
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Limit"), let limit = Double(value), limit > 0 {
            effectiveSpacing = max(minimumSpacing, 60 / limit + 0.1)
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0", response.statusCode != 429 {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            blockedUntil = max(Date().addingTimeInterval(1), reset ?? Date().addingTimeInterval(60))
        }
    }
    func execute<T: Decodable & Sendable>(_ query: String, variables: [String: MLValue] = [:],
                                         as: T.Type, refresh: Bool = false, mutation: Bool = false,
                                         requiresAuth: Bool = false, notBefore: ContinuousClock.Instant? = nil, cacheResponse: Bool = true) async throws -> MLResult<T> {
        guard !stopped else { throw MLError.stopped }
        try gate.check()
        try Task.checkCancellation()
        if requiresAuth && token == nil { throw MLError.authentication }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Request(query: query, variables: variables))
        let key = String(decoding: body, as: UTF8.self)
        let epoch = cacheEpoch
        let authorization = authorizationEpoch
        let requestKey = key + "@\(epoch)"
        // Authenticated queries can contain private fields even on media pages.
        // Never place those responses in the shared public cache.
        let cache = token == nil ? publicCache : accountCache
        var cached = mutation || !cacheResponse ? nil : await cache?.read(key)
        try gate.check()
        try Task.checkCancellation()
        guard !stopped, authorization == authorizationEpoch else { throw CancellationError() }
        // A damaged or older-schema cache entry is a miss, not a persistent
        // loading failure. Decode once for both fresh and offline reuse.
        var saved: (value: T, partial: Bool)?
        if let entry = cached {
            do { saved = try decode(entry.data, as: T.self) }
            catch { cached = nil }
        }
        if !refresh, let cached, let decoded = saved, cached.invalidated != true, Date().timeIntervalSince(cached.storedAt) < (cached.prepared == true ? 1800 : 300) {
            return MLResult(value: decoded.value, cachedAt: Date().timeIntervalSince(cached.storedAt) >= 300 ? cached.storedAt : nil, isPartial: decoded.partial)
        }
        do {
            let consumer = UUID()
            let taskKey = mutation ? requestKey + consumer.uuidString : requestKey
            let flight: Flight
            if !mutation, var shared = inFlight[taskKey] {
                // An explicit Submit joining a typing request wakes its debounce;
                // the ordinary API pacing gate still applies.
                if notBefore == nil { shared.typingDelay?.cancel() }
                shared.consumers.insert(consumer)
                inFlight[taskKey] = shared
                flight = shared
            } else {
                if blockedUntil > Date() { throw MLError.rateLimited(blockedUntil) }
                let bearer = token
                let typingDelay = notBefore.map { deadline in
                    Task<Void, Never> { try? await Task.sleep(until: deadline, clock: .continuous) }
                }
                let task = Task<Data, Error> { [session, gate, weak self] in
                    try gate.check()
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    // Typing debounce belongs after cache lookup: warm results and
                    // explicit searches never wait, obsolete input stays cancellable.
                    await withTaskCancellationHandler {
                        await typingDelay?.value
                    } onCancel: { typingDelay?.cancel() }
                    try Task.checkCancellation()
                    try await self.permitRequest()
                    var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("NokoCord-MaoList/1.0 (native AniList client)", forHTTPHeaderField: "User-Agent")
                    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
                    let (data, response) = try await session.data(for: request)
                    guard data.count <= 8_000_000, let http = response as? HTTPURLResponse else { throw MLError.invalidResponse }
                    await self.receiveRateHeaders(http)
                    if http.statusCode == 429 {
                        let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                        throw MLError.rateLimited(Date().addingTimeInterval(max(1, retry)))
                    }
                    if http.statusCode == 401 { throw MLError.authentication }
                    if http.statusCode >= 500 || http.statusCode == 403 { throw MLError.unavailable }
                    guard (200..<300).contains(http.statusCode) else { throw mutation ? MLError.rejected : MLError.invalidResponse }
                    return data
                }
                flight = Flight(id: UUID(), task: task, typingDelay: typingDelay, consumers: [consumer])
                inFlight[taskKey] = flight
            }
            defer { releaseFlight(taskKey, id: flight.id, consumer: consumer) }
            let data = try await withTaskCancellationHandler { try await flight.task.value } onCancel: {
                Task { await self.releaseFlight(taskKey, id: flight.id, consumer: consumer) }
            }
            try Task.checkCancellation()
            try gate.check()
            guard !stopped, authorization == authorizationEpoch else { throw CancellationError() }
            let value = try decode(data, as: T.self, allowPartial: !mutation)
            if mutation {
                cacheEpoch += 1
                await accountCache?.invalidate()
            } else if cacheResponse, epoch == cacheEpoch { await cache?.write(data, key: key) }
            try gate.check(); try Task.checkCancellation()
            guard !stopped, authorization == authorizationEpoch else { throw CancellationError() }
            return MLResult(value: value.value, cachedAt: nil, isPartial: value.partial)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || stopped || Task.isCancelled { throw CancellationError() }
            // An obsolete request's failure must not restore private cached
            // content or invalidate a replacement account's authorization.
            guard authorization == authorizationEpoch else { throw CancellationError() }
            if case MLError.rateLimited(let until) = error { blockedUntil = until }
            if error as? MLError == .authentication {
                cancelRequests()
                token = nil
                authorizationEpoch += 1
                authenticationFailure?()
                throw error
            }
            if !mutation, let cached, let decoded = saved {
                return MLResult(value: decoded.value, cachedAt: cached.storedAt, isPartial: decoded.partial)
            }
            throw (error as? MLError) ?? .offline
        }
    }
    func preparationEpoch() -> Int { cacheEpoch }
    private struct PreparedEnvelope<T: Encodable>: Encodable { let data: T }
    func cachePrepared<T: Encodable & Sendable>(_ query: String, variables: [String: MLValue], value: T, epoch: Int) async throws {
        try gate.check(); try Task.checkCancellation()
        guard !stopped, token != nil, epoch == cacheEpoch, let cache = accountCache else { throw CancellationError() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = String(decoding: try encoder.encode(Request(query: query, variables: variables)), as: UTF8.self)
        let data = try encoder.encode(PreparedEnvelope(data: value))
        await cache.write(data, key: key, prepared: true)
    }
    /// Cache-only foreground hydration must never silently start networking.
    func cached<T: Decodable & Sendable>(_ query: String, variables: [String: MLValue], as: T.Type) async throws -> MLResult<T>? {
        try gate.check(); try Task.checkCancellation()
        guard !stopped, token != nil, let cache = accountCache else { return nil }
        let epoch = cacheEpoch, authorization = authorizationEpoch
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = String(decoding: try encoder.encode(Request(query: query, variables: variables)), as: UTF8.self)
        guard let entry = await cache.read(key), entry.invalidated != true, Date().timeIntervalSince(entry.storedAt) < (entry.prepared == true ? 1800 : 300) else { return nil }
        try gate.check(); try Task.checkCancellation()
        guard !stopped, token != nil, epoch == cacheEpoch, authorization == authorizationEpoch else { throw CancellationError() }
        let value = try decode(entry.data, as: T.self)
        return MLResult(value: value.value, cachedAt: Date().timeIntervalSince(entry.storedAt) >= 300 ? entry.storedAt : nil, isPartial: value.partial)
    }
    private func decode<T: Decodable>(_ data: Data, as: T.Type, allowPartial: Bool = true) throws -> (value: T, partial: Bool) {
        // Classify expired authorization before decoding potentially malformed
        // partial data. Never fall back to cached private data after a 401.
        if let errors = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).errors {
            if errors.contains(where: { $0.status == 401 }) { throw MLError.authentication }
            if errors.contains(where: { $0.status == 429 }) { throw MLError.rateLimited(Date().addingTimeInterval(60)) }
        }
        let result: Envelope<T>
        do { result = try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch let error as MLError { throw error }
        catch {
            // Record only the schema location, never response values, auth URLs
            // or the error description (which can contain account data).
            let context: DecodingError.Context?
            let kind: String
            switch error {
            case DecodingError.typeMismatch(_, let value): context = value; kind = "type mismatch"
            case DecodingError.valueNotFound(_, let value): context = value; kind = "missing value"
            case DecodingError.keyNotFound(_, let value): context = value; kind = "missing key"
            case DecodingError.dataCorrupted(let value): context = value; kind = "invalid value"
            default: context = nil; kind = "invalid envelope"
            }
            let fields: Set<String> = ["data", "Viewer", "User", "avatar", "large", "medium", "mediaListOptions", "scoreFormat", "animeList", "mangaList", "customLists", "advancedScoring", "advancedScoringEnabled", "sectionOrder", "splitCompletedSectionByFormat", "statistics", "anime", "manga", "count", "statuses", "status", "unreadNotificationCount", "errors"]
            let path = context?.codingPath.map { fields.contains($0.stringValue) ? $0.stringValue : "<field>" }.joined(separator: ".") ?? "envelope"
            Logger(subsystem: "com.shiikatan.nokocord.maomao.maolist", category: "decoding").error("AniList decode failed: \(kind, privacy: .public) at \(path, privacy: .public)")
            throw MLError.invalidResponse
        }
        if let errors = result.errors, !errors.isEmpty {
            if errors.contains(where: { $0.status == 401 }) { throw MLError.authentication }
            if errors.contains(where: { $0.status == 429 }) { throw MLError.rateLimited(Date().addingTimeInterval(60)) }
            // Do not mislabel an auth failure as a successful partial response.
            guard allowPartial, let data = result.data else { throw MLError.rejected }
            return (data, true)
        }
        guard let data = result.data else { throw MLError.invalidResponse }
        return (data, false)
    }
}
