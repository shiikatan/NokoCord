import Foundation

/// Keyless album-cover lookup used only after the existing Apple lookup misses.
/// Match both album and credited artist; never use a loosely related first hit.
actor MusicBrainzArtworkSource: AppleMusicArtworkSource {
    private struct SearchResponse: Decodable {
        struct ReleaseGroup: Decodable {
            struct Credit: Decodable {
                struct Artist: Decodable { let name: String }
                let name: String?
                let joinphrase: String?
                let artist: Artist
            }
            let id: String
            let title: String
            let artistCredit: [Credit]
            enum CodingKeys: String, CodingKey {
                case id, title
                case artistCredit = "artist-credit"
            }
            var creditedName: String {
                artistCredit.map { ($0.name ?? $0.artist.name) + ($0.joinphrase ?? "") }.joined()
            }
        }
        let releaseGroups: [ReleaseGroup]
        enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
    }

    private struct CoverResponse: Decodable {
        struct Image: Decodable {
            let front: Bool
            let thumbnails: [String: URL]?
        }
        let images: [Image]
    }

    private struct CachedCover {
        let url: URL?
        let expiresAt: Date
    }

    private let session: URLSession
    private let userAgent: String
    private let clock = ContinuousClock()
    private var nextSearchTime = ContinuousClock.now
    private var covers: [String: CachedCover] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        session = URLSession(configuration: configuration)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0"
        userAgent = "NokoCord/\(version) (+https://github.com/shiikatan/NokoCord)"
    }

    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        let album = (track.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = (track.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = albumArtist.isEmpty ? (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : albumArtist
        guard !Task.isCancelled, !Self.normalized(album).isEmpty, !Self.normalized(artist).isEmpty,
              album.utf8.count <= 512, artist.utf8.count <= 512 else { return nil }
        let key = Self.normalized(artist) + "|" + Self.normalized(album)
        if let cached = covers[key], cached.expiresAt > Date() { return cached.url }

        do {
            // Recheck after every suspension so concurrent lookups cannot burst
            // through MusicBrainz's one-request-per-second limit.
            while clock.now < nextSearchTime {
                try await clock.sleep(until: nextSearchTime)
            }
            try Task.checkCancellation()
            if let cached = covers[key], cached.expiresAt > Date() { return cached.url }
            nextSearchTime = clock.now.advanced(by: .milliseconds(1100))

            var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
            components.queryItems = [
                URLQueryItem(name: "query", value: "releasegroup:\(Self.phrase(album)) AND artist:\(Self.phrase(artist))"),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "10")
            ]
            guard let searchURL = components.url else { return nil }
            let results: SearchResponse = try await fetchJSON(searchURL)
            let matches = results.releaseGroups.filter {
                Self.normalized($0.title) == Self.normalized(album)
                    && Self.normalized($0.creditedName) == Self.normalized(artist)
                    && UUID(uuidString: $0.id) != nil
            }
            for group in matches.prefix(1) {
                try Task.checkCancellation()
                let coverURL = URL(string: "https://coverartarchive.org/release-group/\(group.id)")!
                // A missing cover for one exact album edition may have another match.
                guard let cover: CoverResponse = try? await fetchJSON(coverURL) else {
                    try Task.checkCancellation()
                    continue
                }
                for image in cover.images where image.front {
                    for size in ["500", "large", "250", "small"] {
                        guard let thumbnail = image.thumbnails?[size],
                              var imageComponents = URLComponents(url: thumbnail, resolvingAgainstBaseURL: false),
                              ["http", "https"].contains(imageComponents.scheme?.lowercased() ?? "") else { continue }
                        // Older CAA metadata uses HTTP; publish its HTTPS equivalent.
                        imageComponents.scheme = "https"
                        guard let url = imageComponents.url,
                              let valid = AppleMusicArtworkURL.validCoverArtArchiveURL(url) else { continue }
                        try Task.checkCancellation()
                        cache(valid, for: key)
                        return valid
                    }
                }
            }
        } catch {
            if Task.isCancelled { return nil }
        }
        guard !Task.isCancelled else { return nil }
        cache(nil, for: key)
        return nil
    }

    private func fetchJSON<Value: Decodable>(_ url: URL) async throws -> Value {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 2 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func cache(_ url: URL?, for key: String) {
        covers = covers.filter { $0.value.expiresAt > Date() }
        covers[key] = CachedCover(url: url, expiresAt: Date().addingTimeInterval(url == nil ? 10 * 60 : 6 * 60 * 60))
        if covers.count > 96, let oldest = covers.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            covers.removeValue(forKey: oldest)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func phrase(_ value: String) -> String {
        let escaped = value.map { character -> String in
            "+-!():^[]\"{}~*?|&\\/".contains(character) ? "\\" + String(character) : String(character)
        }.joined()
        return "\"" + escaped + "\""
    }
}
