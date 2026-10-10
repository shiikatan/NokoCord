import Foundation
import Observation

/// A returning screen can replace a cancelled load that is still unwinding.
/// Only the newest request may publish data or clear the loading indicator.
@MainActor @Observable
final class MLReadRequest {
    private(set) var loading = false
    @ObservationIgnored private var lease = UUID()
    func begin(replacing: Bool = false) -> UUID? {
        guard !loading || replacing else { return nil }
        lease = UUID(); loading = true
        return lease
    }
    func owns(_ id: UUID) -> Bool { lease == id }
    func finish(_ id: UUID) { if owns(id) { loading = false } }
}

/// Explicit read buttons have the same visibility lifetime as automatic loads.
/// Mutations use their own completion handling and never run through this owner.
@MainActor
final class MLReadActions {
    private var task: Task<Void, Never>?
    private var lease = UUID()
    private var active = true
    func setActive(_ value: Bool) {
        active = value
        if !value { cancel() }
    }
    func cancel() { lease = UUID(); task?.cancel(); task = nil }
    func run(_ action: @escaping @MainActor () async -> Void) {
        guard active else { return }
        cancel()
        let id = UUID(); lease = id
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await action()
            if self?.lease == id { self?.task = nil }
        }
    }
}

@MainActor @Observable
final class MLPageStore {
    private(set) var data = MLPage()
    private(set) var page = 0
    private(set) var loading = false
    private(set) var error: String?
    private(set) var staleDate: Date?
    private(set) var partial = false
    private(set) var earlierPagesReleased = false
    @ObservationIgnored private var lease = UUID()
    @ObservationIgnored private var retentionLimit = MLPageWindow.limit
    @ObservationIgnored private var initialKey: String?
    @ObservationIgnored private var initialLoadedAt: Date?
    @ObservationIgnored private var retryReset = false
    var queryIdentity: String { initialKey ?? "" }
    func loadInitial(key: String, refresh: Bool = false, request: (Int) async throws -> MLResult<MLPageData>) async {
        if !refresh, initialKey == key, page > 0, error == nil, !partial,
           let initialLoadedAt, Date().timeIntervalSince(initialLoadedAt) < 300 { return }
        let sameKey = initialKey == key
        // The key identifies displayed data, including partial/failed refreshes.
        // Freshness is separate so a partial result is always retryable.
        if !sameKey { initialKey = key; initialLoadedAt = nil }
        let loaded = await load(reset: true, preservingData: sameKey && page > 0, request: request)
        if loaded, initialKey == key, !partial { initialLoadedAt = Date() }
    }
    /// Hydrate already prepared pages without a network request or dropping the
    /// beginning of the library. The opt-in pass is bounded to 200 pages per list.
    func hydratePreparedPages(count: Int, request: (Int) async throws -> MLResult<MLPageData>?) async {
        let last = min(count, 200)
        retentionLimit = max(MLPageWindow.limit, last * 40)
        while page > 0 && page < last && hasNext && !loading && !Task.isCancelled {
            do {
                let originalPage = page, originalLease = lease, originalKey = initialKey
                guard let result = try await request(originalPage + 1) else { return }
                try Task.checkCancellation()
                guard originalLease == lease, originalKey == initialKey, originalPage == page, !loading else { return }
                guard await load(request: { _ in result }) else { return }
            } catch { return }
        }
    }
    var hasNext: Bool { data.pageInfo?.hasNextPage == true }
    @discardableResult
    func load(reset: Bool = false, preservingData: Bool = false, request: (Int) async throws -> MLResult<MLPageData>) async -> Bool {
        if loading && !reset { return false }
        let id = UUID(); lease = id; loading = true; error = nil
        let resetting = reset || retryReset
        let keepingData = preservingData || (!reset && retryReset && page > 0)
        if resetting && !keepingData { page = 0; data = MLPage(); retentionLimit = MLPageWindow.limit; earlierPagesReleased = false; staleDate = nil; partial = false }
        if resetting && keepingData && staleDate == nil { staleDate = initialLoadedAt }
        let next = resetting ? 1 : page + 1
        defer { if lease == id { loading = false } }
        do {
            let result = try await request(next)
            try Task.checkCancellation()
            guard lease == id else { return false }
            guard let incoming = result.value.Page else { throw MLError.invalidResponse }
            if resetting || page == 0 {
                data = incoming; earlierPagesReleased = false
                staleDate = nil; partial = false
            }
            else {
                data.pageInfo = incoming.pageInfo
                data.media = merge(data.media, incoming.media)
                data.mediaList = merge(data.mediaList, incoming.mediaList)
                data.activities = merge(data.activities, incoming.activities)
                data.activityReplies = merge(data.activityReplies, incoming.activityReplies)
                data.following = merge(data.following, incoming.following)
                data.followers = merge(data.followers, incoming.followers)
                data.notifications = merge(data.notifications, incoming.notifications)
            }
            page = next; partial = partial || result.isPartial
            retryReset = false
            if resetting, !partial { initialLoadedAt = Date() }
            if let date = result.cachedAt { staleDate = min(staleDate ?? date, date) }
            return true
        } catch {
            guard lease == id, !(error is CancellationError), !Task.isCancelled else { return false }
            self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription
            retryReset = resetting
            return false
        }
    }
    private func merge<T: Identifiable>(_ old: [T?]?, _ new: [T?]?) -> [T?]? {
        guard old != nil || new != nil else { return nil }
        let merged = MLPageWindow.merge((old ?? []).compactMap { $0 }, (new ?? []).compactMap { $0 }, maximum: retentionLimit)
        earlierPagesReleased = earlierPagesReleased || merged.released
        return merged.items.map { Optional($0) }
    }
}

@MainActor @Observable
final class MLMediaSectionState {
    private(set) var media: MLMedia?
    private(set) var page = 0
    private(set) var next = false
    private(set) var error: String?
    private(set) var stale: Date?
    private(set) var partial = false
    private(set) var earlierPagesReleased = false
    private let request = MLReadRequest()
    var loading: Bool { request.loading }
    func load(repository: MLRepository, mediaID: Int, section: MLRepository.MediaSection, replacing: Bool = false) async {
        let retrying = error != nil
        guard let lease = request.begin(replacing: replacing) else { return }; error = nil
        defer { request.finish(lease) }
        do {
            let result = try await repository.mediaSection(mediaID, section: section, page: page + 1, refresh: retrying)
            try Task.checkCancellation()
            guard request.owns(lease) else { return }
            guard let incoming = result.value.Media else { throw MLError.invalidResponse }
            let hasConnection: Bool
            switch section {
            case .characters: hasConnection = incoming.characters?.nodes != nil
            case .staff: hasConnection = incoming.staff?.nodes != nil
            case .recommendations: hasConnection = incoming.recommendations?.nodes != nil
            case .reviews: hasConnection = incoming.reviews?.nodes != nil
            }
            guard hasConnection else { throw MLError.invalidResponse }
            var merged = media ?? incoming
            merged.characters = merge(media?.characters, incoming.characters)
            merged.staff = merge(media?.staff, incoming.staff)
            merged.recommendations = merge(media?.recommendations, incoming.recommendations)
            merged.reviews = merge(media?.reviews, incoming.reviews)
            media = merged
            partial = partial || result.isPartial
            if let date = result.cachedAt { stale = min(stale ?? date, date) }
            page += 1
            next = [incoming.characters?.pageInfo?.hasNextPage, incoming.staff?.pageInfo?.hasNextPage, incoming.recommendations?.pageInfo?.hasNextPage, incoming.reviews?.pageInfo?.hasNextPage].contains(true)
        } catch { if request.owns(lease), !Task.isCancelled, !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func merge<T: Codable & Sendable & Identifiable>(_ old: MLConnection<T>?, _ incoming: MLConnection<T>?) -> MLConnection<T>? {
        let result = MLPageWindow.merge(old, incoming)
        earlierPagesReleased = earlierPagesReleased || result.released
        return result.connection
    }
}
