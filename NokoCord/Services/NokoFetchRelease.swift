import Foundation

enum NokoFetchError: LocalizedError, Equatable {
    case metadata, noRelease, missingZIP, missingChecksum, ambiguous, unsafeURL
    case http(Int), network, timeout, oversized, incomplete, checksum, validation, versionMismatch, storage

    var errorDescription: String? {
        switch self {
        case .metadata: "GitHub returned invalid release information. Try again later or choose a local ZIP."
        case .noRelease: "No stable Maomao release is available on GitHub."
        case .missingZIP: "The latest Maomao release is missing its update ZIP."
        case .missingChecksum: "The release is missing its ZIP checksum. Noko-Fetch cannot verify it."
        case .ambiguous: "The release contains conflicting versions or assets. Choose a verified local ZIP instead."
        case .unsafeURL: "The release download address does not match the official repository."
        case .http(403), .http(429): "GitHub is limiting requests. Try again later or choose a local ZIP."
        case .http: "GitHub could not provide this release. Try again later."
        case .network: "Could not reach GitHub. Check your connection or choose a local ZIP."
        case .timeout: "The GitHub request timed out. Try again when your connection is ready."
        case .oversized: "The release exceeds the supported download size."
        case .incomplete: "The download is incomplete. Nothing was installed; try again."
        case .checksum: "The ZIP did not match its published SHA-256 checksum. Nothing was installed."
        case .validation: "The downloaded ZIP failed the updater’s app, archive, or compatibility checks. Nothing was installed."
        case .versionMismatch: "The app inside the ZIP does not match the release version. Nothing was installed."
        case .storage: "Could not prepare private update storage. Close other Maomao instances and try again."
        }
    }
}

struct NokoFetchRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let state: String
        let browser_download_url: String
    }
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

struct NokoFetchSelection: Sendable {
    let version: ManualUpdateVersion
    let tag: String
    let zip: NokoFetchRelease.Asset
    let checksum: NokoFetchRelease.Asset

    static let repository = "https://github.com/shiikatan/NokoCord"
    static let maximumZIPSize: Int64 = 768 * 1024 * 1024
    static let maximumChecksumSize: Int64 = 64 * 1024

    /// Select the highest stable marketing version, not GitHub's mixed-edition
    /// `latest` endpoint or publication order. An incomplete newest release fails
    /// closed instead of silently selecting an older package.
    static func latest(in releases: [NokoFetchRelease]) throws -> Self {
        var eligible: [(NokoFetchRelease, ManualUpdateVersion)] = []
        for release in releases where !release.draft && !release.prerelease {
            guard release.tag_name.hasPrefix("maomao-") else { continue }
            guard release.tag_name.hasPrefix("maomao-M"),
                  let version = try? ManualUpdateVersion(String(release.tag_name.dropFirst(8))),
                  release.tag_name == "maomao-M\(version)",
                  release.html_url == "\(repository)/releases/tag/\(release.tag_name)" else {
                throw NokoFetchError.metadata
            }
            eligible.append((release, version))
        }
        guard let version = eligible.map(\.1).max() else { throw NokoFetchError.noRelease }
        let matching = eligible.filter { $0.1 == version }
        guard matching.count == 1, let release = matching.first?.0 else { throw NokoFetchError.ambiguous }
        let zipName = "NokoCord-Maomao-M\(version).zip"
        let zips = release.assets.filter { $0.name == zipName }
        let sums = release.assets.filter { $0.name == "SHA256SUMS" }
        guard !zips.isEmpty else { throw NokoFetchError.missingZIP }
        guard !sums.isEmpty else { throw NokoFetchError.missingChecksum }
        guard zips.count == 1, sums.count == 1 else { throw NokoFetchError.ambiguous }
        let zip = zips[0], checksum = sums[0]
        for (asset, limit) in [(zip, maximumZIPSize), (checksum, maximumChecksumSize)] {
            guard asset.state == "uploaded", asset.size > 0, asset.size <= limit else { throw NokoFetchError.metadata }
            guard asset.browser_download_url == "\(repository)/releases/download/\(release.tag_name)/\(asset.name)" else {
                throw NokoFetchError.unsafeURL
            }
        }
        return Self(version: version, tag: release.tag_name, zip: zip, checksum: checksum)
    }

    /// The actual published `shasum -a 256` format. Only simple filenames are
    /// accepted; duplicate entries (even identical ones) and malformed lines fail.
    static func zipDigest(in data: Data, filename: String) throws -> String {
        guard data.count <= maximumChecksumSize, let text = String(data: data, encoding: .utf8) else {
            throw NokoFetchError.checksum
        }
        var entries: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            guard line.range(of: "^[0-9a-fA-F]{64} [ *][A-Za-z0-9][A-Za-z0-9._-]{0,199}$", options: .regularExpression) != nil else {
                throw NokoFetchError.checksum
            }
            let name = String(line.dropFirst(66))
            guard entries[name] == nil else { throw NokoFetchError.ambiguous }
            entries[name] = String(line.prefix(64)).lowercased()
        }
        guard let digest = entries[filename] else { throw NokoFetchError.missingChecksum }
        return digest
    }
}
