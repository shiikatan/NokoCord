import Foundation
import Darwin

protocol NokoFetchInspecting: Sendable {
    func inspect(zipURL: URL) async throws -> ManualUpdateCandidate
    func discardCandidate(_ candidate: ManualUpdateCandidate) async throws
}

extension ManualUpdateService: NokoFetchInspecting {}

enum NokoFetchProgress: Sendable {
    case checking
    case downloading(version: String, received: Int64, total: Int64)
    case verifying
    case inspecting
}

enum NokoFetchResult: Sendable {
    case upToDate(ManualUpdateVersion)
    case ready(ManualUpdateCandidate, filename: String)
}

/// Acquisition ends at `inspect(zipURL:)`. The manual updater owns the private
/// candidate snapshot, all installation checks, confirmations and helper handoff.
actor NokoFetchService {
    private let paths: MaomaoDataPaths
    private let transport: any NokoFetchDownloading

    init(paths: MaomaoDataPaths = MaomaoDataPaths(), transport: any NokoFetchDownloading = NokoFetchTransport()) {
        self.paths = paths
        self.transport = transport
    }

    func fetch(currentVersion: ManualUpdateVersion, updater: any NokoFetchInspecting,
               progress: @escaping @Sendable (NokoFetchProgress) -> Void) async throws -> NokoFetchResult {
        let workspace = try NokoFetchWorkspace(paths: paths)
        defer { workspace.close() }
        var inspectedCandidate: ManualUpdateCandidate?
        do {
            try Task.checkCancellation()
            progress(.checking)
            var releases: [NokoFetchRelease] = []
            // Enumerate the bounded public release history so mixed editions or
            // a republished older tag cannot change version ordering.
            for page in 1...10 {
                let url = URL(string: "https://api.github.com/repos/shiikatan/NokoCord/releases?per_page=100&page=\(page)")!
                let file = workspace.directory.appendingPathComponent("releases-\(page).json")
                try await transport.download(url, to: file, limit: 4 * 1024 * 1024, expectedSize: nil, progress: { _ in })
                try Task.checkCancellation()
                guard let batch = try? JSONDecoder().decode([NokoFetchRelease].self, from: Data(contentsOf: file)),
                      batch.count <= 100 else { throw NokoFetchError.metadata }
                releases.append(contentsOf: batch)
                if batch.count < 100 { break }
                if page == 10 { throw NokoFetchError.metadata }
            }
            let selection = try NokoFetchSelection.latest(in: releases)
            guard selection.version > currentVersion else { return .upToDate(selection.version) }
            let sumFile = workspace.directory.appendingPathComponent("SHA256SUMS")
            try await transport.download(URL(string: selection.checksum.browser_download_url)!, to: sumFile,
                                         limit: NokoFetchSelection.maximumChecksumSize, expectedSize: selection.checksum.size, progress: { _ in })
            try Task.checkCancellation()
            let expected = try NokoFetchSelection.zipDigest(in: Data(contentsOf: sumFile), filename: selection.zip.name)
            let zipFile = workspace.directory.appendingPathComponent(selection.zip.name)
            progress(.downloading(version: "M\(selection.version)", received: 0, total: selection.zip.size))
            try await transport.download(URL(string: selection.zip.browser_download_url)!, to: zipFile,
                                         limit: selection.zip.size, expectedSize: selection.zip.size) { received in
                progress(.downloading(version: "M\(selection.version)", received: received, total: selection.zip.size))
            }
            try Task.checkCancellation()
            progress(.verifying)
            guard try ManualUpdateDigest.file(at: zipFile) == expected else { throw NokoFetchError.checksum }
            try Task.checkCancellation()
            progress(.inspecting)
            let candidate: ManualUpdateCandidate
            do { candidate = try await updater.inspect(zipURL: zipFile) }
            catch { throw NokoFetchError.validation }
            inspectedCandidate = candidate
            try Task.checkCancellation()
            guard candidate.marketingVersion == selection.version, candidate.archiveSHA256 == expected else {
                throw NokoFetchError.versionMismatch
            }
            guard candidate.permits(.update) else { throw NokoFetchError.validation }
            return .ready(candidate, filename: selection.zip.name)
        } catch {
            if let inspectedCandidate { try? await updater.discardCandidate(inspectedCandidate) }
            throw error
        }
    }

    /// Called once at Maomao startup; no networking and no effect on local ZIP
    /// candidates. The lease prevents cleanup of another running acquisition.
    nonisolated static func removeStaleDownloads(paths: MaomaoDataPaths) {
        if let workspace = try? NokoFetchWorkspace(paths: paths) { workspace.close() }
    }
}

private final class NokoFetchWorkspace {
    let directory: URL
    private var lockDescriptor: Int32

    init(paths: MaomaoDataPaths) throws {
        let root = paths.cacheRoot.appendingPathComponent("NokoFetch", isDirectory: true)
        try MaomaoDataPaths.createPrivateDirectory(root)
        let lockURL = root.appendingPathComponent(".lock")
        try MaomaoDataPaths.validateNoSymlinkComponents(at: lockURL)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NokoFetchError.storage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw NokoFetchError.storage
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where UUID(uuidString: entry.lastPathComponent) != nil {
                try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(entry)
            }
            try MaomaoDataPaths.createPrivateDirectory(directory)
        } catch {
            Darwin.close(descriptor)
            throw NokoFetchError.storage
        }
        self.directory = directory
        lockDescriptor = descriptor
    }

    func close() {
        guard lockDescriptor >= 0 else { return }
        try? ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(directory)
        flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

    deinit { close() }
}
