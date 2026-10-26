import Foundation

/// Keyless, read-only metadata. Never sends user/account identifiers or tokens.
actor DeezerArtworkSource: AppleMusicArtworkSource {
    private struct Artist: Decodable { let name: String; let picture_big: URL? }
    private struct Album: Decodable { let title: String; let artist: Artist?; let cover_big: URL? }
    private struct Track: Decodable { let title: String; let artist: Artist; let album: Album }
    private struct Results<Value: Decodable>: Decodable { let data: [Value] }
    private struct Cached { let url: URL?; let expiresAt: Date }
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let spacing: Duration
    private let clock = ContinuousClock()
    private var nextRequest = ContinuousClock.now
    private var covers: [String: Cached] = [:]

    init(session: URLSession? = nil, minimumSpacing: Duration = .seconds(1),
         now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.now = now; spacing = minimumSpacing
    }
    private static func albumMetadata(_ track: AppleMusicTrackSnapshot) -> (artist: String, album: String, key: String)? {
        let album = (track.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = (track.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = albumArtist.isEmpty ? (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : albumArtist
        guard permitted(album), permitted(artist) else { return nil }
        return (artist, album, "album|" + normalized(artist) + "|" + normalized(album))
    }
    private static func trackMetadata(_ track: AppleMusicTrackSnapshot) -> (artist: String, title: String, key: String)? {
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard permitted(artist), permitted(track.title) else { return nil }
        return (artist, track.title, "track|" + normalized(artist) + "|" + normalizedSong(track.title))
    }
    func cachedArtworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if let metadata = Self.albumMetadata(track), let cached = covers[metadata.key], cached.expiresAt > now(), let url = cached.url { return url }
        if let metadata = Self.trackMetadata(track), let cached = covers[metadata.key], cached.expiresAt > now() { return cached.url }
        return nil
    }
    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if let metadata = Self.albumMetadata(track) {
            if let cached = covers[metadata.key], cached.expiresAt > now() {
                if let url = cached.url { return url }
            } else {
                let result: Results<Album>? = await fetch("/search/album", query: metadata.artist + " " + metadata.album)
                guard !Task.isCancelled else { return nil }
                let targetAlbum = Self.normalized(metadata.album), targetArtist = Self.normalized(metadata.artist)
                let cover = result?.data.lazy.filter {
                    Self.normalized($0.title) == targetAlbum &&
                    Self.normalized($0.artist?.name ?? "") == targetArtist
                }.compactMap { $0.cover_big.flatMap(AppleMusicArtworkURL.validDeezerArtworkURL) }.first
                cache(cover, for: metadata.key)
                if let cover { return cover }
            }
        }
        // A reissue/compilation may use another cover. Require the same artist
        // and song; never mistake live, remix or acoustic titles for the original.
        guard let metadata = Self.trackMetadata(track) else { return nil }
        if let cached = covers[metadata.key], cached.expiresAt > now() { return cached.url }
        let result: Results<Track>? = await fetch("/search", query: metadata.artist + " " + metadata.title)
        guard !Task.isCancelled else { return nil }
        let targetArtist = Self.normalized(metadata.artist), targetSong = Self.normalizedSong(metadata.title)
        let cover = result?.data.lazy.filter {
            Self.normalized($0.artist.name) == targetArtist &&
            Self.normalizedSong($0.title) == targetSong
        }.compactMap { $0.album.cover_big.flatMap(AppleMusicArtworkURL.validDeezerArtworkURL) }.first
        // Track-only matches never populate an album cache under another album.
        cache(cover, for: metadata.key)
        return cover
    }
    func artistImageURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled, Self.permitted(artist) else { return nil }
        let key = "artist|" + Self.normalized(artist)
        if let cached = covers[key], cached.expiresAt > now() { return cached.url }
        let result: Results<Artist>? = await fetch("/search/artist", query: artist)
        guard !Task.isCancelled else { return nil }
        let targetArtist = Self.normalized(artist)
        let image = result?.data.lazy.filter { Self.normalized($0.name) == targetArtist }
            .compactMap { $0.picture_big.flatMap(AppleMusicArtworkURL.validDeezerArtistImageURL) }.first
        cache(image, for: key); return image
    }
    private func fetch<Value: Decodable>(_ path: String, query: String) async -> Value? {
        do {
            while clock.now < nextRequest { try await clock.sleep(until: nextRequest) }
            try Task.checkCancellation()
            nextRequest = clock.now.advanced(by: spacing)
            var components = URLComponents(string: "https://api.deezer.com" + path)!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "10")]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else { return nil }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch { return nil }
    }
    private func cache(_ url: URL?, for key: String) {
        covers = covers.filter { $0.value.expiresAt > now() }
        covers[key] = Cached(url: url, expiresAt: now().addingTimeInterval(url == nil ? AppleMusicArtworkPolicy.retryInterval : 6 * 60 * 60))
        if covers.count > 96, let oldest = covers.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key { covers.removeValue(forKey: oldest) }
    }
    private static func permitted(_ value: String) -> Bool { !normalized(value).isEmpty && value.utf8.count <= 512 }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static let remasterTag = try! NSRegularExpression(pattern: #"(?i)\s*[\(\[]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+(?:in\s+)?\d{4})?\s*[\)\]]\s*"#)
    private static let remasterSuffix = try! NSRegularExpression(pattern: #"(?i)\s*[-–—]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*$"#)
    private static func normalizedSong(_ value: String) -> String {
        var text = value
        for expression in [remasterTag, remasterSuffix] {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return normalized(text)
    }
}
