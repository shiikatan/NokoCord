import Foundation

/// Select one backup service, avoiding a long chain of network requests.
struct AppleMusicFallbackArtworkSource: AppleMusicArtworkSource {
    private let source: any AppleMusicArtworkSource

    init() {
        if let key = Bundle.main.object(forInfoDictionaryKey: "NokoLastFMAPIKey") as? String,
           key.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil {
            source = LastFMArtworkSource(apiKey: key)
        } else {
            source = MusicBrainzArtworkSource()
        }
    }

    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        await source.artworkURL(for: track)
    }

    func cachedArtworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        await source.cachedArtworkURL(for: track)
    }
}

/// Read-only Last.fm metadata. No user sign-in, scrobbling, or shared secret.
actor LastFMArtworkSource: AppleMusicArtworkSource {
    private struct Image: Decodable {
        let size: String
        let text: String
        enum CodingKeys: String, CodingKey { case size; case text = "#text" }
    }
    private struct Album: Decodable {
        let name: String
        let artist: String
        let image: [Image]?
    }
    private struct AlbumResponse: Decodable { let album: Album? }
    private struct TrackResponse: Decodable {
        struct Track: Decodable {
            struct Artist: Decodable { let name: String }
            struct TrackAlbum: Decodable { let image: [Image]? }
            let name: String
            let artist: Artist
            let album: TrackAlbum?
        }
        let track: Track?
    }
    private struct CachedCover {
        let url: URL?
        let expiresAt: Date
    }

    private let apiKey: String
    private let session: URLSession
    private let clock = ContinuousClock()
    private var nextRequestTime = ContinuousClock.now
    private var covers: [String: CachedCover] = [:]

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        session = URLSession(configuration: configuration)
    }

    func cachedArtworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let albumArtist = (track.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = albumArtist.isEmpty ? (track.artist ?? "") : albumArtist
        let keys = [
            "album|" + Self.normalized(artist) + "|" + Self.normalized(track.album ?? ""),
            "track|" + Self.normalized(track.artist ?? "") + "|" + Self.normalized(track.title)
        ]
        for key in keys {
            if let cached = covers[key], cached.expiresAt > Date(), let url = cached.url { return url }
        }
        return nil
    }

    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (track.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = (track.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let creditedArtist = albumArtist.isEmpty ? artist : albumArtist
        guard [title, artist, album, creditedArtist].allSatisfy({ $0.utf8.count <= 512 }) else { return nil }

        // Album lookup covers multi-artist soundtracks and is reused across
        // tracks. An exact track lookup handles absent album covers/metadata.
        if !Self.normalized(album).isEmpty, !Self.normalized(creditedArtist).isEmpty {
            let key = "album|" + Self.normalized(creditedArtist) + "|" + Self.normalized(album)
            if let cached = covers[key], cached.expiresAt > Date() {
                if let url = cached.url { return url }
            } else {
                let response: AlbumResponse? = await fetch("album.getInfo", parameters: ["artist": creditedArtist, "album": album])
                guard !Task.isCancelled else { return nil }
                let result = response?.album
                let url = result.flatMap { result in
                    Self.normalized(result.name) == Self.normalized(album)
                        && Self.normalized(result.artist) == Self.normalized(creditedArtist) ? Self.cover(from: result.image) : nil
                }
                cache(url, for: key)
                if let url { return url }
            }
        }
        guard !Self.normalized(title).isEmpty, !Self.normalized(artist).isEmpty else { return nil }
        let key = "track|" + Self.normalized(artist) + "|" + Self.normalized(title)
        if let cached = covers[key], cached.expiresAt > Date() { return cached.url }
        let response: TrackResponse? = await fetch("track.getInfo", parameters: ["artist": artist, "track": title])
        guard !Task.isCancelled else { return nil }
        let url = response?.track.flatMap { result in
            Self.normalized(result.name) == Self.normalized(title)
                && Self.normalized(result.artist.name) == Self.normalized(artist) ? Self.cover(from: result.album?.image) : nil
        }
        cache(url, for: key)
        return url
    }

    private func fetch<Value: Decodable>(_ method: String, parameters: [String: String]) async -> Value? {
        do {
            while clock.now < nextRequestTime { try await clock.sleep(until: nextRequestTime) }
            try Task.checkCancellation()
            nextRequestTime = clock.now.advanced(by: .milliseconds(1100))
            var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
            components.queryItems = [
                URLQueryItem(name: "method", value: method),
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "autocorrect", value: "0")
            ] + parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024 else { return nil }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            // Do not log request URLs, which contain the application API key.
            return nil
        }
    }

    private func cache(_ url: URL?, for key: String) {
        covers = covers.filter { $0.value.expiresAt > Date() }
        covers[key] = CachedCover(url: url, expiresAt: Date().addingTimeInterval(url == nil ? 10 * 60 : 6 * 60 * 60))
        if covers.count > 96, let oldest = covers.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            covers.removeValue(forKey: oldest)
        }
    }

    private static func cover(from images: [Image]?) -> URL? {
        for size in ["extralarge", "mega", "large", "medium", "small"] {
            for image in images ?? [] where image.size == size {
                guard let url = URL(string: image.text), let valid = AppleMusicArtworkURL.validLastFMArtworkURL(url) else { continue }
                return valid
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}
