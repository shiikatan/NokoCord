import Foundation
import Darwin

/// Keeps one small current-build package; complete apps exist only in owned
/// temporary staging and the preserving updater's bounded transaction.
actor NokoIconSwitchService {
    private let currentApp: URL
    private let paths: MaomaoDataPaths
    private let transport: any NokoFetchDownloading
    private let updater: ManualUpdateService

    init(currentApp: URL = Bundle.main.bundleURL, paths: MaomaoDataPaths = MaomaoDataPaths(),
         transport: any NokoFetchDownloading = NokoFetchTransport()) {
        self.currentApp = currentApp; self.paths = paths; self.transport = transport
        updater = ManualUpdateService(currentAppURL: currentApp, paths: paths)
    }

    func prepare(_ icon: NokoAppIcon, progress: @escaping @Sendable (String) -> Void) async throws -> ManualUpdateCandidate {
        let metadata = try ManualUpdateApplicationMetadata.read(from: currentApp)
        guard metadata.bundleIdentifier == MaomaoDataPaths.bundleIdentifier, metadata.editionID == "maomao" else { throw ManualUpdateError.unsupportedEdition }
        let cache = paths.cacheRoot.appendingPathComponent("IconVariants", isDirectory: true)
        try MaomaoDataPaths.createPrivateDirectory(cache)
        let lockURL = cache.appendingPathComponent("switch.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NokoFetchError.storage }
        defer { close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else { throw NokoFetchError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ManualUpdateError.unavailable("Another icon change is already being prepared.") }
        defer { _ = flock(fd, LOCK_UN) }
        // With the lock held, leftover owned workspaces came from an interrupted
        // preparation. They contain no user data and need not accumulate.
        for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            if url.lastPathComponent.hasPrefix("work-"), UUID(uuidString: String(url.lastPathComponent.dropFirst(5))) != nil {
                try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(url)
            }
        }
        let work = cache.appendingPathComponent("work-" + UUID().uuidString, isDirectory: true)
        try MaomaoDataPaths.createPrivateDirectory(work)
        defer { try? ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(work) }
        let version = metadata.marketingVersion.description, build = metadata.build.description
        let filename = "NokoCord-Maomao-M\(version)-Icons.nokoicons"
        let cached = cache.appendingPathComponent("M\(version)-\(build).nokoicons")
        progress("Checking icon files…")
        var cachedPackage: NokoIconVariantPackage?
        if FileManager.default.fileExists(atPath: cached.path) {
            do {
                let found = try NokoIconVariantPackage.decode(Self.readBounded(cached, limit: NokoIconVariantPackage.maximumSize))
                guard found.version == version, found.build == build else { throw NokoIconVariantError.differentBuild }
                cachedPackage = found
            } catch {
                // A bounded corrupt regular cache file can be fetched again.
                // Never follow a substituted link or remove an unrelated path.
                try MaomaoDataPaths.validateNoSymlinkComponents(at: cached)
                var info = stat()
                guard lstat(cached.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw NokoFetchError.storage }
                try ManualUpdateTransactionFiles.removeOwnedPath(cached)
            }
        }
        let package: NokoIconVariantPackage
        if let cachedPackage { package = cachedPackage } else {
            progress("Downloading small verified icon files…")
            let prefix = "\(NokoFetchSelection.repository)/releases/download/maomao-M\(version)/"
            let sums = work.appendingPathComponent("SHA256SUMS")
            try await transport.download(URL(string: prefix + "SHA256SUMS")!, to: sums,
                limit: NokoFetchSelection.maximumChecksumSize, expectedSize: nil, progress: { _ in })
            let expected = try NokoFetchSelection.zipDigest(in: Self.readBounded(sums, limit: Int(NokoFetchSelection.maximumChecksumSize)), filename: filename)
            let downloaded = work.appendingPathComponent(filename)
            try await transport.download(URL(string: prefix + filename)!, to: downloaded,
                limit: Int64(NokoIconVariantPackage.maximumSize), expectedSize: nil, progress: { _ in })
            guard try ManualUpdateDigest.file(at: downloaded) == expected else { throw NokoFetchError.checksum }
            package = try NokoIconVariantPackage.decode(Self.readBounded(downloaded, limit: NokoIconVariantPackage.maximumSize))
            guard package.version == version, package.build == build else { throw NokoIconVariantError.differentBuild }
            try FileManager.default.moveItem(at: downloaded, to: cached)
        }
        guard package.version == version, package.build == build else { throw NokoIconVariantError.differentBuild }
        // Only this app's current-version package remains after a successful read.
        for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if url != cached, name.range(of: #"^M[0-9]+(?:\.[0-9]+){1,3}-[0-9]+\.nokoicons$"#, options: .regularExpression) != nil {
                try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
                try ManualUpdateTransactionFiles.removeOwnedPath(url)
            }
        }
        try Task.checkCancellation()
        progress("Preparing the signed icon variant…")
        let app = work.appendingPathComponent("NokoCord.app", isDirectory: true)
        try package.reconstruct(from: currentApp, to: app, icon: icon)
        let target = try ManualUpdateApplicationMetadata.read(from: app)
        _ = try SystemManualUpdateAppValidator().validate(appURL: app, executableURL: target.executableURL)
        try Task.checkCancellation()
        // Existing updater inspection, identity, signature, rollback and relaunch
        // checks remain authoritative; the icon route never uses Clean Reinstall.
        let zip = work.appendingPathComponent("icon-switch.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, zip.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NokoFetchError.storage }
        try Task.checkCancellation()
        progress("Verifying the replacement…")
        let candidate = try await updater.inspect(zipURL: zip, preservingExistingCandidates: true)
        guard candidate.classification == .sameVersionCleanReinstall else {
            try? await updater.discardCandidate(candidate); throw NokoIconVariantError.differentBuild
        }
        if Task.isCancelled {
            try? await updater.discardCandidate(candidate); throw CancellationError()
        }
        return candidate
    }

    func apply(_ candidate: ManualUpdateCandidate) async throws {
        do {
            _ = try await updater.apply(candidate: candidate, operation: .changeIcon)
            // The helper owns its independent verified staging now. Remove the
            // temporary ZIP and inspection copy before the old process exits.
            try? await updater.discardCandidate(candidate)
        } catch {
            try? await updater.discardCandidate(candidate)
            throw error
        }
    }

    func discard(_ candidate: ManualUpdateCandidate) async { try? await updater.discardCandidate(candidate) }

    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NokoFetchError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { throw NokoFetchError.oversized }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size, data.count <= limit else { throw NokoFetchError.incomplete }
        return data
    }
}
