import CryptoKit
import Darwin
import Foundation

enum ManualUpdateTanImportBlockReason: Equatable, Sendable {
    case sourceMissing
    case alreadyCompleted
    case scopedStorageExists
    case unsupportedBaseline
    case noValidatedPackages
    case invalidSource(String)
}

struct ManualUpdateTanImportAvailability: Equatable, Sendable {
    let eligible: Bool
    let sourcePath: String
    let sourceDigest: String?
    let packageNames: [String]
    let packageCount: Int
    let translatedArchiveCount: Int
    let enabledCount: Int
    let safeMode: Bool
    let reason: ManualUpdateTanImportBlockReason?
}

struct ManualUpdateTanImportResult: Equatable, Sendable {
    let packageNames: [String]
    let packageCount: Int
    let translatedArchiveCount: Int
    let enabledCount: Int
    let sourcePath: String
    let sourcePreserved: Bool
    let tanManagerRefreshed: Bool
}

private struct ManualUpdateLegacyTanState: Codable {
    let version: Int
    let enabled: [String]
    let safeMode: Bool
    let enableLog: [String]
}

private struct ManualUpdateLegacyTanArchive: Decodable {
    let report: TanTranslationReport
    let files: [String: String]
}

private struct ValidatedLegacyTanDirectory {
    let files: [String: Data]
    let packages: [TanPackage]
    let sourceDigest: String
    let enabled: [String]
    let safeMode: Bool
    let enableLog: [String]
    let translatedArchiveIDs: Set<String>

    var packageNames: [String] { packages.map(\.manifest.name).sorted() }
}

enum ManualUpdateLegacyTanImporter {
    private static let packageLimit = 2 * 1024 * 1024
    private static let stateLimit = 128 * 1024
    private static let archiveLimit = 16 * 1024 * 1024
    private static let fileCountLimit = 256
    private static let totalSelectedLimit = 64 * 1024 * 1024

    static func availability(paths: MaomaoDataPaths) -> ManualUpdateTanImportAvailability {
        let source = paths.legacySharedTanStorage
        func blocked(_ reason: ManualUpdateTanImportBlockReason, preview: ValidatedLegacyTanDirectory? = nil) -> ManualUpdateTanImportAvailability {
            ManualUpdateTanImportAvailability(
                eligible: false,
                sourcePath: source.path,
                sourceDigest: preview?.sourceDigest,
                packageNames: preview?.packageNames ?? [],
                packageCount: preview?.packages.count ?? 0,
                translatedArchiveCount: preview?.translatedArchiveIDs.count ?? 0,
                enabledCount: preview?.enabled.count ?? 0,
                safeMode: preview?.safeMode ?? false,
                reason: reason
            )
        }
        var markerInfo = stat()
        if lstat(paths.noLegacyTanImportMarker.path, &markerInfo) == 0 {
            return blocked(.alreadyCompleted)
        } else if errno != ENOENT {
            return blocked(.invalidSource("Could not inspect the one-time import marker."))
        }
        var destinationInfo = stat()
        if lstat(paths.tanStorage.path, &destinationInfo) == 0 {
            return blocked(.scopedStorageExists)
        } else if errno != ENOENT {
            return blocked(.invalidSource("Could not inspect Maomao's Tan storage."))
        }
        var sourceInfo = stat()
        if lstat(source.path, &sourceInfo) != 0 {
            return errno == ENOENT ? blocked(.sourceMissing) : blocked(.invalidSource("Could not inspect the shared Tan folder."))
        }
        do {
            let directory = try inspect(source)
            guard !directory.packages.isEmpty else { return blocked(.noValidatedPackages, preview: directory) }
            return ManualUpdateTanImportAvailability(
                eligible: true,
                sourcePath: source.path,
                sourceDigest: directory.sourceDigest,
                packageNames: directory.packageNames,
                packageCount: directory.packages.count,
                translatedArchiveCount: directory.translatedArchiveIDs.count,
                enabledCount: directory.enabled.count,
                safeMode: directory.safeMode,
                reason: nil
            )
        } catch {
            return blocked(.invalidSource(error.localizedDescription))
        }
    }

    /// Explicit one-time operation. `expectedSourceDigest` binds confirmation
    /// to the read-only preview returned by `availability`.
    static func importOnce(paths: MaomaoDataPaths, expectedSourceDigest: String) throws -> ManualUpdateTanImportResult {
        guard !expectedSourceDigest.isEmpty else { throw ManualUpdateError.staleCandidate }
        let current = availability(paths: paths)
        guard current.eligible, current.sourceDigest == expectedSourceDigest else {
            if let reason = current.reason { throw ManualUpdateError.unavailable(String(describing: reason)) }
            throw ManualUpdateError.staleCandidate
        }
        let validated = try inspect(paths.legacySharedTanStorage)
        guard validated.sourceDigest == expectedSourceDigest else { throw ManualUpdateError.staleCandidate }

        try MaomaoDataPaths.createPrivateDirectory(paths.editionRoot)
        var destinationInfo = stat()
        guard lstat(paths.tanStorage.path, &destinationInfo) != 0, errno == ENOENT else {
            throw ManualUpdateError.unavailable("Maomao Tan storage already exists; it was left unchanged.")
        }
        let staging = paths.editionRoot.appendingPathComponent(".Tans-import-\(UUID().uuidString)", isDirectory: true)
        try MaomaoDataPaths.createPrivateDirectory(staging)
        var published = false
        defer {
            if !published { try? ManualUpdateTransactionFiles.removeOwnedPath(staging) }
        }

        for (name, data) in validated.files where name != "state.json" {
            try writeNewRegularFile(data, name: name, in: staging)
        }
        let importedIDs = Set(validated.packages.map(\.id))
        let safeState = ManualUpdateLegacyTanState(
            version: 1,
            enabled: validated.enabled.filter(importedIDs.contains),
            safeMode: validated.safeMode,
            enableLog: validated.enableLog.filter(importedIDs.contains)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeNewRegularFile(encoder.encode(safeState), name: "state.json", in: staging)

        let sanitizedStateData = try encoder.encode(safeState)
        try validateStagedFiles(validated.files, sanitizedState: sanitizedStateData, at: staging)
        try MaomaoDataPaths.validateNoSymlinkComponents(at: staging)
        try ManualUpdateTransactionFiles.renameSameVolume(from: staging, to: paths.tanStorage, expectedSource: .directory)
        published = true

        let marker = paths.noLegacyTanImportMarker
        try MaomaoDataPaths.createPrivateDirectory(marker.deletingLastPathComponent())
        do {
            try ManualUpdateTransactionFiles.writeDurably(
                "user-approved shared Tan import; source left unchanged\n",
                to: marker,
                replace: false
            )
        } catch {
            try? ManualUpdateTransactionFiles.removeOwnedPath(paths.tanStorage)
            published = false
            throw error
        }
        return ManualUpdateTanImportResult(
            packageNames: validated.packageNames,
            packageCount: validated.packages.count,
            translatedArchiveCount: validated.translatedArchiveIDs.count,
            enabledCount: safeState.enabled.count,
            sourcePath: paths.legacySharedTanStorage.path,
            sourcePreserved: true,
            tanManagerRefreshed: false
        )
    }

    private static func inspect(_ source: URL) throws -> ValidatedLegacyTanDirectory {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: source)
        let root = try ManualUpdateTransactionFiles.openDirectoryNoFollow(source.path)
        defer { close(root) }
        let scanFD = dup(root)
        guard scanFD >= 0, let stream = fdopendir(scanFD) else {
            if scanFD >= 0 { close(scanFD) }
            throw ManualUpdateError.unsafePath("Could not enumerate the shared Tan folder.")
        }
        defer { closedir(stream) }

        var names: [String] = []
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            guard names.count <= fileCountLimit else { throw ManualUpdateError.unsafePath("Shared Tan folder contains too many entries.") }
        }

        var selected: [String: Data] = [:]
        var packages: [String: TanPackage] = [:]
        var state: ManualUpdateLegacyTanState?
        var sourceHasher = SHA256()
        var selectedTotal = 0
        for name in names.sorted() {
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,160}$", options: .regularExpression) != nil else {
                throw ManualUpdateError.unsafePath("Shared Tan folder contains an unsafe filename.")
            }
            var info = stat()
            guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else {
                throw ManualUpdateError.unsafePath("Shared Tan folder must contain regular files only.")
            }
            sourceHasher.update(data: Data("entry\0\(name)\0\(info.st_dev)\0\(info.st_ino)\0\(info.st_size)\0\(info.st_mtimespec.tv_sec)\0\(info.st_mtimespec.tv_nsec)\0\(info.st_ctimespec.tv_sec)\0\(info.st_ctimespec.tv_nsec)\n".utf8))
            let kind: String?
            let limit: Int
            if name == "state.json" { kind = "state"; limit = stateLimit }
            else if name.hasSuffix(".tan.json") { kind = "package"; limit = packageLimit }
            else if name.hasSuffix(".source.json") { kind = "archive"; limit = archiveLimit }
            else { kind = nil; limit = 0 }

            if let kind {
                let data = try readRegularFile(directory: root, name: name, limit: limit)
                selectedTotal += data.count
                guard selectedTotal <= totalSelectedLimit else { throw ManualUpdateError.unsafePath("Selected Tan data exceeds the import limit.") }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                sourceHasher.update(data: Data("selected\0\(name)\0\(data.count)\0\(digest)\n".utf8))
                if kind == "state" {
                    state = try JSONDecoder().decode(ManualUpdateLegacyTanState.self, from: data)
                    selected[name] = data
                } else if kind == "package" {
                    let package = try JSONDecoder().decode(TanPackage.self, from: data)
                    try package.validate()
                    let id = String(name.dropLast(".tan.json".count))
                    guard id == package.id, packages[id] == nil else { throw ManualUpdateError.invalidApplication("A shared Tan package filename or identifier is invalid.") }
                    if package.manifest.target == .native {
                        guard TanPackage.originals.contains(where: { $0.id == package.id && $0.origin == package.origin && $0.contentHash == package.contentHash }) else {
                            throw ManualUpdateError.invalidApplication("A shared native Tan does not match this app's bundled original.")
                        }
                    }
                    packages[id] = package
                    selected[name] = data
                } else {
                    let packageID = String(name.dropLast(".source.json".count))
                    guard let package = packages[packageID], package.origin == "Translated Tan" else { continue }
                    try validateTranslationArchive(data)
                    selected[name] = data
                }
            }
        }
        // Translation archives can appear before their corresponding package
        // in directory order. Include only validated matching archives.
        let translatedIDs = Set(packages.values.filter { $0.origin == "Translated Tan" }.map(\.id))
        for name in names where name.hasSuffix(".source.json") {
            let id = String(name.dropLast(".source.json".count))
            guard translatedIDs.contains(id), selected[name] == nil else { continue }
            let data = try readRegularFile(directory: root, name: name, limit: archiveLimit)
            try validateTranslationArchive(data)
            selected[name] = data
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            sourceHasher.update(data: Data("archive\0\(name)\0\(data.count)\0\(digest)\n".utf8))
        }
        guard packages.count <= 64 else { throw ManualUpdateError.unsafePath("Shared Tan folder exceeds the 64-package limit.") }

        let importedIDs = Set(packages.keys)
        let storedState = state ?? ManualUpdateLegacyTanState(version: 1, enabled: [], safeMode: false, enableLog: [])
        guard storedState.version == 1,
              storedState.enabled.count <= 64,
              storedState.enableLog.count <= 64,
              Set(storedState.enabled).count == storedState.enabled.count,
              storedState.enabled.allSatisfy(isSafeTanID),
              storedState.enableLog.allSatisfy(isSafeTanID) else {
            throw ManualUpdateError.invalidApplication("Shared Tan state is invalid.")
        }
        // Don't restore enable grants for package IDs that aren't imported.
        let enabled = storedState.enabled.filter(importedIDs.contains)
        let enableLog = storedState.enableLog.filter(importedIDs.contains)
        selected.removeValue(forKey: "state.json") // Re-encoded with sanitized IDs during import.
        let finalDigest = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ValidatedLegacyTanDirectory(
            files: selected,
            packages: Array(packages.values).sorted { $0.manifest.name < $1.manifest.name },
            sourceDigest: finalDigest,
            enabled: enabled,
            safeMode: storedState.safeMode,
            enableLog: enableLog,
            translatedArchiveIDs: Set(selected.keys.filter { $0.hasSuffix(".source.json") }.map { String($0.dropLast(".source.json".count)) })
        )
    }

    private static func readRegularFile(directory: Int32, name: String, limit: Int) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("Could not open a shared Tan file safely.") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else {
            throw ManualUpdateError.unsafePath("A shared Tan file is not a bounded regular file.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, min(buffer.count, limit - data.count + 1))
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("Could not read a shared Tan file.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw ManualUpdateError.unsafePath("A shared Tan file exceeds the import limit.") }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ManualUpdateError.staleCandidate
        }
        return data
    }

    private static func validateTranslationArchive(_ data: Data) throws {
        let archive = try JSONDecoder().decode(ManualUpdateLegacyTanArchive.self, from: data)
        guard archive.report.installable, archive.files.count <= 128,
              !archive.files.isEmpty, archive.files.values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024,
              archive.files.keys.allSatisfy({ safeRelativeArchivePath($0) }),
              archive.report.files.count == archive.files.count else {
            throw ManualUpdateError.invalidApplication("A translated Tan source archive is invalid.")
        }
        let digests = Dictionary(uniqueKeysWithValues: archive.report.files.map { ($0.path, $0.sha256.lowercased()) })
        guard digests.count == archive.report.files.count,
              archive.files.allSatisfy({ path, text in
                  guard let expected = digests[path] else { return false }
                  let actual = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                  return expected == actual
              }) else {
            throw ManualUpdateError.invalidApplication("A translated Tan source archive does not match its file checksums.")
        }
    }

    private static func safeRelativeArchivePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeTanID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9.-]{2,79}$", options: .regularExpression) != nil
            && !id.contains("..") && !id.hasSuffix(".")
    }

    private static func writeNewRegularFile(_ data: Data, name: String, in directory: URL) throws {
        let directoryFD = try ManualUpdateTransactionFiles.openDirectoryNoFollow(directory.path)
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("Could not stage imported Tan data.") }
        defer { close(descriptor) }
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unavailable("Could not write imported Tan data.")
            }
            offset += amount
        }
        guard fsync(descriptor) == 0, fsync(directoryFD) == 0 else {
            throw ManualUpdateError.unavailable("Could not sync imported Tan data.")
        }
    }

    private static func validateStagedFiles(_ files: [String: Data], sanitizedState: Data, at directory: URL) throws {
        let directoryFD = try ManualUpdateTransactionFiles.openDirectoryNoFollow(directory.path)
        defer { close(directoryFD) }
        let expected = files.merging(["state.json": sanitizedState]) { _, new in new }
        for (name, bytes) in expected {
            let actual = try readRegularFile(directory: directoryFD, name: name, limit: max(bytes.count, 1))
            guard actual == bytes else { throw ManualUpdateError.unavailable("Imported Tan files changed while staging.") }
        }
        let scanFD = dup(directoryFD)
        guard scanFD >= 0, let stream = fdopendir(scanFD) else {
            if scanFD >= 0 { close(scanFD) }
            throw ManualUpdateError.unsafePath("Could not verify staged Tan files.")
        }
        defer { closedir(stream) }
        var actualNames = Set<String>()
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { actualNames.insert(name) }
        }
        guard actualNames == Set(expected.keys) else { throw ManualUpdateError.unsafePath("Staged Tan directory contains unexpected files.") }
    }
}
