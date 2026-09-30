import CryptoKit
import Darwin
import Foundation

struct ManualUpdateProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func current() throws -> Self {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result == MemoryLayout<proc_bsdinfo>.size else {
            throw ManualUpdateError.unavailable("Could not capture this app process identity.")
        }
        return Self(pid: getpid(), startSeconds: UInt64(info.pbi_start_tvsec), startMicroseconds: UInt64(info.pbi_start_tvusec))
    }

    func stillMatchesRunningProcess() -> Bool {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return result == MemoryLayout<proc_bsdinfo>.size
            && UInt64(info.pbi_start_tvsec) == startSeconds
            && UInt64(info.pbi_start_tvusec) == startMicroseconds
    }
}

struct ManualUpdateDirectoryIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func read(at url: URL) throws -> ManualUpdateDirectoryIdentity {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_ino != 0 else {
            throw ManualUpdateError.unsafePath("application directory identity could not be read")
        }
        return ManualUpdateDirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

struct ManualUpdateTransactionManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nonce: String
    let operation: ManualUpdateOperation
    let process: ManualUpdateProcessIdentity
    let applicationPath: String
    let installedApplicationIdentity: ManualUpdateDirectoryIdentity
    let candidateApplicationIdentity: ManualUpdateDirectoryIdentity
    let transactionDirectoryPath: String
    let helperPath: String
    let helperSHA256: String
    let stagedApplicationPath: String
    let backupApplicationPath: String
    let journalPath: String
    let candidateBundleIdentifier: String
    let candidateEditionID: String
    let candidateMarketingVersion: String
    let candidateBuild: String
    let candidateExecutableName: String
    let candidateTreeSHA256: String
    let candidateHelperSHA256: String
    let candidateHelperSignature: String
    let candidateHelperArchitectures: [String]
    let candidateSignature: String
    let candidateArchitectures: [String]
    let installedMarketingVersion: String
    let installedBuild: String
    let installedExecutableName: String
    let installedTreeSHA256: String
    let installedSignature: String
    let installedArchitectures: [String]
    let scopedTanStoragePath: String
    let legacySharedTanStoragePath: String
    let cachePath: String
    let preferencesPath: String
    let savedApplicationStatePath: String
    let candidateRootPath: String
    let noLegacyImportMarkerPath: String
    let pendingUpdateTransactionPath: String
    let pendingCleanResetPath: String
}

enum ManualUpdateJournalState: String, Codable, Sendable {
    case prepared
    case pendingUpdate
    case helperReady
    case waitingForOldProcess
    case oldProcessExited
    case swapInProgress
    case backupMoved
    case replacementInstalled
    case legacyTansCopied
    case cleanFilesCleared
    case launchRequested
    case webKitResetComplete
    case appReady
    case resetIncomplete
    case rollbackStarted
    case rollbackComplete
    case failed
}

struct ManualUpdateJournal: Codable, Equatable, Sendable {
    let nonce: String
    let state: ManualUpdateJournalState
    let message: String?
    let updatedAt: Date

    init(nonce: String, state: ManualUpdateJournalState, message: String? = nil) {
        self.nonce = nonce
        self.state = state
        self.message = message
        self.updatedAt = Date()
    }
}

struct ManualUpdatePendingReset: Codable, Equatable, Sendable {
    let nonce: String
    let manifestPath: String
    let journalPath: String
}

struct ManualUpdatePendingTransaction: Codable, Equatable, Sendable {
    let nonce: String
    let manifestPath: String
    let journalPath: String
}

struct ManualUpdateStartupReceipt: Equatable, Sendable {
    let manifest: ManualUpdateTransactionManifest
    let manifestURL: URL
    let cleanResetCompleted: Bool
    let recoveryLockDescriptor: Int32?
    let startupLockDescriptor: Int32?
}

enum ManualUpdateTransactionFiles {
    enum EntryKind: Equatable { case directory, regularFile }

    static func openDirectoryNoFollow(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !path.contains("//"),
              !components.contains("."), !components.contains("..") else {
            throw ManualUpdateError.unsafePath("directory path is not canonical")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not open filesystem root") }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw ManualUpdateError.unsafePath("symbolic or invalid directory component") }
            descriptor = next
        }
        return descriptor
    }

    static func createTransactionDirectory(for applicationURL: URL, nonce: String) throws -> URL {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: applicationURL.deletingLastPathComponent())
        let parent = applicationURL.deletingLastPathComponent()
        let parentDescriptor = try openDirectoryNoFollow(parent.path)
        defer { close(parentDescriptor) }
        let leaf = ".NokoCord-Update-\(nonce)"
        guard mkdirat(parentDescriptor, leaf, 0o700) == 0 else {
            throw ManualUpdateError.unavailable("Cannot create a same-volume update staging directory beside the app.")
        }
        guard fsync(parentDescriptor) == 0 else { throw ManualUpdateError.unavailable("Could not sync the update staging directory.") }
        return parent.appendingPathComponent(leaf, isDirectory: true)
    }

    static func writeDurably<T: Encodable>(_ value: T, to destination: URL, replace: Bool) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            throw ManualUpdateError.unavailable("Could not encode the update transaction record.")
        }
        let parentDescriptor = try openDirectoryNoFollow(destination.deletingLastPathComponent().path)
        defer { close(parentDescriptor) }
        let leaf = destination.lastPathComponent
        var existing = stat()
        if fstatat(parentDescriptor, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard replace, (existing.st_mode & S_IFMT) == S_IFREG else {
                throw ManualUpdateError.unsafePath("transaction record already exists or is not a regular file")
            }
        } else if errno != ENOENT {
            throw ManualUpdateError.unsafePath("could not inspect transaction record")
        }
        let temporaryLeaf = ".\(leaf).\(UUID().uuidString).tmp"
        let descriptor = openat(parentDescriptor, temporaryLeaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not create transaction record") }
        var shouldUnlink = true
        defer { if shouldUnlink { _ = unlinkat(parentDescriptor, temporaryLeaf, 0) }; close(descriptor) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unavailable("Could not write transaction record.")
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else { throw ManualUpdateError.unavailable("Could not sync transaction record.") }
        let publishResult = replace
            ? renameat(parentDescriptor, temporaryLeaf, parentDescriptor, leaf)
            : renameatx_np(parentDescriptor, temporaryLeaf, parentDescriptor, leaf, UInt32(RENAME_EXCL))
        guard publishResult == 0 else {
            throw ManualUpdateError.unavailable("Could not atomically publish transaction record.")
        }
        shouldUnlink = false
        guard fsync(parentDescriptor) == 0 else { throw ManualUpdateError.unavailable("Could not sync transaction directory.") }
    }

    static func readManifest(at url: URL) throws -> ManualUpdateTransactionManifest {
        let descriptor = try openRegularFileNoFollow(url.path)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= 64 * 1024 else {
            throw ManualUpdateError.unsafePath("transaction manifest is not a bounded regular file")
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("could not read complete transaction manifest")
            }
            guard amount > 0 else { throw ManualUpdateError.unsafePath("could not read complete transaction manifest") }
            offset += amount
        }
        return try JSONDecoder().decode(ManualUpdateTransactionManifest.self, from: data)
    }

    static func openRegularFileNoFollow(_ path: String) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        let parentDescriptor = try openDirectoryNoFollow(url.deletingLastPathComponent().path)
        defer { close(parentDescriptor) }
        let descriptor = openat(parentDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not open regular file") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ManualUpdateError.unsafePath("path is not a regular file")
        }
        return descriptor
    }

    static func copyTreeWithDitto(from source: URL, to destination: URL) throws {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: source)
        var destinationInfo = stat()
        guard lstat(destination.path, &destinationInfo) != 0, errno == ENOENT else {
            throw ManualUpdateError.unsafePath("staging destination already exists")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ManualUpdateError.unavailable("Could not stage the application bundle.") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ManualUpdateError.unavailable("Application staging failed.") }
    }

    static func copyExecutable(from source: URL, to destination: URL) throws {
        let sourceFD = try openRegularFileNoFollow(source.path)
        defer { close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0,
              sourceInfo.st_mode & 0o111 != 0,
              sourceInfo.st_size > 0, sourceInfo.st_size <= 64 * 1024 * 1024 else {
            throw ManualUpdateError.invalidApplication("the bundled updater helper is not a bounded executable")
        }
        let parentFD = try openDirectoryNoFollow(destination.deletingLastPathComponent().path)
        defer { close(parentFD) }
        let output = openat(parentFD, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard output >= 0 else { throw ManualUpdateError.unsafePath("could not copy the updater helper") }
        defer { close(output) }
        var hasher = SHA256()
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(sourceFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unavailable("Could not read the bundled updater helper.")
            }
            copied += Int64(count)
            hasher.update(data: Data(buffer.prefix(count)))
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw in
                    Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ManualUpdateError.unavailable("Could not copy the updater helper.")
                }
                offset += written
            }
        }
        var after = stat()
        guard fstat(sourceFD, &after) == 0, copied == sourceInfo.st_size,
              sourceInfo.st_dev == after.st_dev, sourceInfo.st_ino == after.st_ino,
              sourceInfo.st_size == after.st_size,
              sourceInfo.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              sourceInfo.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              fsync(output) == 0,
              fchmod(output, 0o700) == 0,
              fsync(parentFD) == 0 else {
            throw ManualUpdateError.unavailable("The updater helper changed or failed to sync while being copied.")
        }
        _ = hasher.finalize()
    }

    static func renameSameVolume(from source: URL, to destination: URL, expectedSource: EntryKind) throws {
        let sourceParent = try openDirectoryNoFollow(source.deletingLastPathComponent().path)
        defer { close(sourceParent) }
        let destinationParent = try openDirectoryNoFollow(destination.deletingLastPathComponent().path)
        defer { close(destinationParent) }
        var sourceInfo = stat()
        var destinationInfo = stat()
        let sourceType = expectedSource == .directory ? S_IFDIR : S_IFREG
        guard fstat(sourceParent, &sourceInfo) == 0, fstat(destinationParent, &destinationInfo) == 0,
              sourceInfo.st_dev == destinationInfo.st_dev,
              fstatat(sourceParent, source.lastPathComponent, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (sourceInfo.st_mode & S_IFMT) == sourceType,
              fstatat(destinationParent, destination.lastPathComponent, &destinationInfo, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT,
              renameatx_np(sourceParent, source.lastPathComponent, destinationParent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw ManualUpdateError.unavailable("The application cannot be replaced atomically at this location.")
        }
        guard fsync(sourceParent) == 0, fsync(destinationParent) == 0 else {
            throw ManualUpdateError.unavailable("Could not make the application rename durable.")
        }
    }

    /// Atomically exchanges two existing same-volume application directories.
    /// `RENAME_SWAP` keeps a launchable app at the installation path through
    /// the entire replacement operation, including power loss.
    static func swapSameVolumeDirectories(_ first: URL, _ second: URL) throws {
        let firstParent = try openDirectoryNoFollow(first.deletingLastPathComponent().path)
        defer { close(firstParent) }
        let secondParent = try openDirectoryNoFollow(second.deletingLastPathComponent().path)
        defer { close(secondParent) }
        var firstParentInfo = stat()
        var secondParentInfo = stat()
        var firstInfo = stat()
        var secondInfo = stat()
        guard fstat(firstParent, &firstParentInfo) == 0,
              fstat(secondParent, &secondParentInfo) == 0,
              firstParentInfo.st_dev == secondParentInfo.st_dev,
              fstatat(firstParent, first.lastPathComponent, &firstInfo, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(secondParent, second.lastPathComponent, &secondInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (firstInfo.st_mode & S_IFMT) == S_IFDIR,
              (secondInfo.st_mode & S_IFMT) == S_IFDIR,
              renameatx_np(firstParent, first.lastPathComponent, secondParent, second.lastPathComponent, UInt32(RENAME_SWAP)) == 0 else {
            throw ManualUpdateError.unavailable("The application bundles could not be atomically exchanged on this volume.")
        }
        guard fsync(firstParent) == 0, fsync(secondParent) == 0 else {
            throw ManualUpdateError.unavailable("Could not make the application exchange durable.")
        }
    }

    static func removeOwnedPath(_ url: URL) throws {
        let parent = try openDirectoryNoFollow(url.deletingLastPathComponent().path)
        defer { close(parent) }
        try removeEntry(parentDescriptor: parent, name: url.lastPathComponent)
        guard fsync(parent) == 0 else { throw ManualUpdateError.unavailable("Could not sync removed application data.") }
    }

    /// Removes a verified application bundle without following its internal
    /// framework symlinks. This is intentionally separate from owned-data
    /// deletion, which rejects symlinks entirely.
    static func removeApplicationBundleNoFollow(_ url: URL) throws {
        let parent = try openDirectoryNoFollow(url.deletingLastPathComponent().path)
        defer { close(parent) }
        try removeBundleEntry(parentDescriptor: parent, name: url.lastPathComponent)
        guard fsync(parent) == 0 else { throw ManualUpdateError.unavailable("Could not sync removed application backup.") }
    }

    static func validateTreeHasNoSymlinks(at root: URL) throws {
        let rootFD = try openDirectoryNoFollow(root.path)
        defer { close(rootFD) }
        try validateDirectory(rootFD)
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        let streamDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw ManualUpdateError.unsafePath("could not enumerate an owned data directory")
        }
        defer { closedir(stream) }
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ManualUpdateError.unsafePath("owned data changed during validation")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ManualUpdateError.unsafePath("owned data contains an unsafe directory") }
                do { try validateDirectory(child); close(child) }
                catch { close(child); throw error }
            case S_IFREG: continue
            default: throw ManualUpdateError.unsafePath("owned data contains a symbolic or special file")
            }
        }
    }

    private static func removeEntry(parentDescriptor: Int32, name: String) throws {
        var info = stat()
        guard fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw ManualUpdateError.unsafePath("could not inspect owned path")
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            guard unlinkat(parentDescriptor, name, 0) == 0 else { throw ManualUpdateError.unavailable("Could not remove owned file.") }
        case S_IFDIR:
            let child = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ManualUpdateError.unsafePath("owned directory changed during removal") }
            do {
                try validateDirectory(child)
                try removeContents(child)
                close(child)
            } catch { close(child); throw error }
            guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw ManualUpdateError.unavailable("Could not remove owned directory.")
            }
        default:
            throw ManualUpdateError.unsafePath("owned path contains a symbolic or special file")
        }
    }

    private static func removeContents(_ descriptor: Int32) throws {
        let streamDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw ManualUpdateError.unsafePath("could not enumerate owned data for removal")
        }
        defer { closedir(stream) }
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try removeEntry(parentDescriptor: descriptor, name: name)
        }
    }

    private static func removeBundleEntry(parentDescriptor: Int32, name: String) throws {
        var before = stat()
        guard fstatat(parentDescriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw ManualUpdateError.unsafePath("could not inspect application backup")
        }
        switch before.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK:
            guard unlinkat(parentDescriptor, name, 0) == 0 else {
                throw ManualUpdateError.unavailable("Could not remove application backup entry.")
            }
        case S_IFDIR:
            let child = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ManualUpdateError.unsafePath("application backup changed during removal") }
            do {
                try removeBundleContents(child)
                close(child)
            } catch { close(child); throw error }
            var after = stat()
            guard fstatat(parentDescriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  (after.st_mode & S_IFMT) == S_IFDIR,
                  unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw ManualUpdateError.unsafePath("application backup changed during removal")
            }
        default:
            throw ManualUpdateError.unsafePath("application backup contains a special file")
        }
    }

    private static func removeBundleContents(_ descriptor: Int32) throws {
        let streamDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw ManualUpdateError.unsafePath("could not enumerate application backup")
        }
        defer { closedir(stream) }
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try removeBundleEntry(parentDescriptor: descriptor, name: name)
        }
    }
}
