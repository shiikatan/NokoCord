import CryptoKit
import Foundation
import Darwin

struct ManualUpdateArchiveEntry: Equatable, Sendable {
    let path: String
    let components: [String]
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    var localRecordEnd: UInt64
}

struct ManualUpdateArchiveDescription: Equatable, Sendable {
    let applicationRootName: String
    let entries: [ManualUpdateArchiveEntry]
    let symlinkTargets: [String: String]
}

enum ManualUpdateArchiveInspector {
    static let maximumArchiveSize: UInt64 = 768 * 1024 * 1024
    static let maximumExpandedSize: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumEntryCount = 100_000

    static func inspect(_ archiveURL: URL) throws -> ManualUpdateArchiveDescription {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: archiveURL)
        var fileInfo = stat()
        guard lstat(archiveURL.path, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_size > 0,
              UInt64(fileInfo.st_size) <= maximumArchiveSize else {
            throw ManualUpdateError.invalidArchive("archive is not a regular file or exceeds the size limit")
        }
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard let directory = try centralDirectory(in: data) else {
            throw ManualUpdateError.invalidArchive("ZIP central directory is missing or unsupported")
        }
        guard !directory.entries.isEmpty, directory.entries.count <= maximumEntryCount else {
            throw ManualUpdateError.invalidArchive("ZIP entry count is invalid")
        }

        var totalExpanded: UInt64 = 0
        var roots = Set<String>()
        var normalizedPaths = Set<String>()
        var entriesByPath: [String: ManualUpdateArchiveEntry] = [:]
        var appEntries: [ManualUpdateArchiveEntry] = []
        var appleDoubleEntries: [ManualUpdateArchiveEntry] = []
        for raw in directory.entries {
            let key = raw.components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }.joined(separator: "/")
            guard normalizedPaths.insert(key).inserted else {
                throw ManualUpdateError.invalidArchive("ZIP contains colliding paths")
            }
            let total = totalExpanded.addingReportingOverflow(raw.uncompressedSize)
            totalExpanded = total.partialValue
            guard !total.overflow, totalExpanded <= maximumExpandedSize else {
                throw ManualUpdateError.invalidArchive("expanded application is too large")
            }
            guard raw.compressedSize > 0 || raw.uncompressedSize == 0,
                  raw.uncompressedSize <= maximumExpandedSize,
                  raw.compressedSize == 0 || raw.uncompressedSize / max(1, raw.compressedSize) <= 1000 else {
                throw ManualUpdateError.invalidArchive("ZIP entry expansion is excessive")
            }
            if raw.components.first == "__MACOSX" {
                appleDoubleEntries.append(raw)
            } else {
                let (entry, rootName) = try validate(raw: raw, archive: data, centralOffset: directory.offset)
                roots.insert(rootName)
                guard roots.count == 1 else { throw ManualUpdateError.invalidArchive("ZIP must contain exactly one app bundle") }
                appEntries.append(entry)
                entriesByPath[entry.path] = entry
            }
        }
        guard let root = roots.first, root.hasSuffix(".app"), isSafeBundleName(root) else {
            throw ManualUpdateError.invalidArchive("ZIP does not contain a valid app bundle root")
        }
        try validatePathHierarchy(entriesByPath)
        try validateAppleDoubleMetadata(appleDoubleEntries, appRoot: root, appEntries: entriesByPath)
        let symlinks = try validateArchiveSymlinks(entries: appEntries, archive: archiveURL)
        try validateNonOverlappingLocalData(directory.entries, centralOffset: directory.offset)
        return ManualUpdateArchiveDescription(applicationRootName: root, entries: appEntries, symlinkTargets: symlinks)
    }

    static func extract(_ archiveURL: URL, to destination: URL, description: ManualUpdateArchiveDescription) throws -> URL {
        var destinationInfo = stat()
        guard lstat(destination.path, &destinationInfo) != 0, errno == ENOENT else {
            throw ManualUpdateError.unsafePath("extraction destination must be fresh")
        }
        try MaomaoDataPaths.createPrivateDirectory(destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ManualUpdateError.invalidArchive("could not extract ZIP safely")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManualUpdateError.invalidArchive("ZIP extraction failed")
        }
        let appURL = destination.appendingPathComponent(description.applicationRootName, isDirectory: true)
        try MaomaoDataPaths.validateNoSymlinkComponents(at: appURL)
        var info = stat()
        guard lstat(appURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ManualUpdateError.invalidArchive("app bundle root was not extracted as a directory")
        }
        let extractedRoots = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        guard extractedRoots == [description.applicationRootName] else {
            throw ManualUpdateError.invalidArchive("extraction produced unexpected top-level entries")
        }
        try validateExtractedTree(appURL: appURL, entries: description.entries, symlinkTargets: description.symlinkTargets)
        try validateExtractedSymlinks(appURL: appURL, entries: description.entries, targets: description.symlinkTargets)
        return appURL
    }

    private struct RawCentralDirectory {
        let entries: [ManualUpdateArchiveEntry]
        let offset: Int
    }

    private static func centralDirectory(in data: Data) throws -> RawCentralDirectory? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65_557)
        var endRecord: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if try data.u32(at: offset) == 0x0605_4b50 {
                let commentLength = Int(try data.u16(at: offset + 20))
                if offset + 22 + commentLength == data.count { endRecord = offset; break }
            }
        }
        guard let end = endRecord else { return nil }
        let disk = try data.u16(at: end + 4)
        let directoryDisk = try data.u16(at: end + 6)
        let countOnDisk = try data.u16(at: end + 8)
        let totalCount = try data.u16(at: end + 10)
        let size = UInt64(try data.u32(at: end + 12))
        let offset = UInt64(try data.u32(at: end + 16))
        guard disk == 0, directoryDisk == 0, countOnDisk == totalCount,
              totalCount != UInt16.max, size != UInt32.max, offset != UInt32.max,
              offset + size == UInt64(end), offset <= UInt64(Int.max) else { return nil }
        var cursor = Int(offset)
        var entries: [ManualUpdateArchiveEntry] = []
        entries.reserveCapacity(Int(totalCount))
        for _ in 0..<totalCount {
            guard try data.u32(at: cursor) == 0x0201_4b50 else {
                throw ManualUpdateError.invalidArchive("malformed ZIP central directory")
            }
            let madeBy = try data.u16(at: cursor + 4)
            let flags = try data.u16(at: cursor + 8)
            let method = try data.u16(at: cursor + 10)
            let compressed = try data.u32(at: cursor + 20)
            let expanded = try data.u32(at: cursor + 24)
            let nameLength = Int(try data.u16(at: cursor + 28))
            let extraLength = Int(try data.u16(at: cursor + 30))
            let commentLength = Int(try data.u16(at: cursor + 32))
            let startDisk = try data.u16(at: cursor + 34)
            let external = try data.u32(at: cursor + 38)
            let localOffset = try data.u32(at: cursor + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard cursor + recordLength <= Int(offset + size), nameLength > 0,
                  startDisk == 0, compressed != UInt32.max, expanded != UInt32.max, localOffset != UInt32.max,
                  flags & 0x0001 == 0, flags & 0x0040 == 0,
                  flags & ~UInt16(0x080e) == 0,
                  method == 0 || method == 8 else {
                throw ManualUpdateError.invalidArchive("encrypted, split, or unsupported ZIP entry")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ManualUpdateError.invalidArchive("ZIP entry name is not UTF-8")
            }
            let mode = UInt16((external >> 16) & 0xffff)
            let fileType = mode & 0xf000
            let unixHost = madeBy >> 8 == 3 || madeBy >> 8 == 19
            let dosDirectory = external & 0x10 != 0
            let isDirectory = name.hasSuffix("/") || dosDirectory || fileType == 0x4000
            let isSymlink = unixHost && fileType == 0xa000
            if unixHost, fileType != 0, fileType != 0x8000, fileType != 0x4000, fileType != 0xa000 {
                throw ManualUpdateError.invalidArchive("special files are not allowed in an app archive")
            }
            if isSymlink, isDirectory { throw ManualUpdateError.invalidArchive("invalid ZIP symlink type") }
            let path = try validatedPath(name, isDirectory: isDirectory)
            let components = path.split(separator: "/").map(String.init)
            var entry = ManualUpdateArchiveEntry(
                path: path, components: components, isDirectory: isDirectory, isSymbolicLink: isSymlink,
                compressionMethod: method, crc32: try data.u32(at: cursor + 16),
                compressedSize: UInt64(compressed), uncompressedSize: UInt64(expanded),
                localHeaderOffset: UInt64(localOffset), localRecordEnd: 0
            )
            entry.localRecordEnd = try validateLocalHeader(for: entry, flags: flags, archive: data, centralOffset: Int(offset))
            try validateExtraFields(in: data, start: cursor + 46 + nameLength, length: extraLength)
            entries.append(entry)
            cursor += recordLength
        }
        guard cursor == Int(offset + size) else { throw ManualUpdateError.invalidArchive("central directory length is inconsistent") }
        return RawCentralDirectory(entries: entries, offset: Int(offset))
    }

    private static func validate(raw: ManualUpdateArchiveEntry, archive: Data, centralOffset: Int) throws -> (ManualUpdateArchiveEntry, String) {
        let components = raw.components
        guard let root = components.first, components.count >= 2 || raw.isDirectory,
              root.hasSuffix(".app"), isSafeBundleName(root),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
            throw ManualUpdateError.invalidArchive("ZIP contains a path outside its single app bundle")
        }
        guard raw.path.utf8.count <= 2048, components.allSatisfy({ $0.utf8.count <= 255 }) else {
            throw ManualUpdateError.invalidArchive("ZIP path is too long")
        }
        guard raw.compressedSize > 0 || raw.uncompressedSize == 0,
              raw.uncompressedSize <= maximumExpandedSize,
              raw.compressedSize == 0 || raw.uncompressedSize / max(1, raw.compressedSize) <= 1000 else {
            throw ManualUpdateError.invalidArchive("ZIP entry expansion is excessive")
        }
        return (raw, root)
    }

    /// `ditto -c -k --sequesterRsrc --keepParent` emits a top-level
    /// `__MACOSX/<app>` tree containing AppleDouble resource-fork files.
    /// Permit only `._name` files that map onto an existing app entry and
    /// directories that mirror app directories; ditto consumes these during
    /// extraction. This keeps the actual candidate root limited to one app.
    private static func validateAppleDoubleMetadata(
        _ metadata: [ManualUpdateArchiveEntry],
        appRoot: String,
        appEntries: [String: ManualUpdateArchiveEntry]
    ) throws {
        guard !metadata.isEmpty else { return }
        let appPaths = Set(appEntries.keys.map { String($0.dropFirst(appRoot.count + 1)) })
        var appDirectories = Set<String>()
        for path in appPaths {
            let components = path.split(separator: "/").map(String.init)
            if components.count > 1 {
                for length in 1..<components.count { appDirectories.insert(components.prefix(length).joined(separator: "/")) }
            }
            if appEntries[appRoot + "/" + path]?.isDirectory == true { appDirectories.insert(path) }
        }
        for entry in metadata {
            let parts = entry.components
            guard !entry.isSymbolicLink, parts.first == "__MACOSX" else {
                throw ManualUpdateError.invalidArchive("invalid AppleDouble metadata entry")
            }
            if parts.count == 1 {
                guard entry.isDirectory else { throw ManualUpdateError.invalidArchive("invalid AppleDouble metadata root") }
                continue
            }
            guard parts[1] == appRoot else { throw ManualUpdateError.invalidArchive("AppleDouble metadata targets another bundle") }
            if parts.count == 2 {
                guard entry.isDirectory else { throw ManualUpdateError.invalidArchive("invalid AppleDouble bundle root") }
                continue
            }
            let mirrored = Array(parts.dropFirst(2))
            let parentComponents = Array(mirrored.dropLast())
            let parent = parentComponents.joined(separator: "/")
            guard !parentComponents.contains(where: { $0.hasPrefix("._") }),
                  parent.isEmpty || appDirectories.contains(parent) else {
                throw ManualUpdateError.invalidArchive("AppleDouble metadata path is not contained in the app")
            }
            let leaf = mirrored.last!
            if entry.isDirectory {
                guard !leaf.hasPrefix("._"), appDirectories.contains(mirrored.joined(separator: "/")) else {
                    throw ManualUpdateError.invalidArchive("AppleDouble directories must mirror app directories")
                }
            } else {
                guard !entry.isSymbolicLink, leaf.hasPrefix("._"), leaf.count > 2 else {
                    throw ManualUpdateError.invalidArchive("only AppleDouble resource files are allowed in __MACOSX")
                }
                let targetLeaf = String(leaf.dropFirst(2))
                let targetPath = parent.isEmpty ? targetLeaf : parent + "/" + targetLeaf
                guard appPaths.contains(targetPath) else {
                    throw ManualUpdateError.invalidArchive("AppleDouble file does not map to an app entry")
                }
            }
        }
    }

    private static func validatedPath(_ name: String, isDirectory: Bool) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value == 0 }),
              !name.hasPrefix("~") else {
            throw ManualUpdateError.invalidArchive("absolute or malformed ZIP path")
        }
        let trimmed = isDirectory && name.hasSuffix("/") ? String(name.dropLast()) : name
        let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ManualUpdateError.invalidArchive("ZIP path traversal component")
        }
        return pieces.map(String.init).joined(separator: "/")
    }

    private static func isSafeBundleName(_ value: String) -> Bool {
        guard value.hasSuffix(".app"), value.utf8.count <= 128,
              let first = value.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 32 || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    private static func validateLocalHeader(for entry: ManualUpdateArchiveEntry, flags: UInt16, archive: Data, centralOffset: Int) throws -> UInt64 {
        guard entry.localHeaderOffset <= UInt64(Int.max) else { throw ManualUpdateError.invalidArchive("invalid local file header") }
        let offset = Int(entry.localHeaderOffset)
        guard try archive.u32(at: offset) == 0x0403_4b50 else { throw ManualUpdateError.invalidArchive("invalid local file header") }
        let localFlags = try archive.u16(at: offset + 6)
        let method = try archive.u16(at: offset + 8)
        let localCRC = try archive.u32(at: offset + 14)
        let localCompressed = try archive.u32(at: offset + 18)
        let localExpanded = try archive.u32(at: offset + 22)
        let nameLength = Int(try archive.u16(at: offset + 26))
        let extraLength = Int(try archive.u16(at: offset + 28))
        guard localFlags == flags, method == entry.compressionMethod,
              offset + 30 + nameLength + extraLength <= centralOffset,
              let localName = String(data: archive.subdata(in: (offset + 30)..<(offset + 30 + nameLength)), encoding: .utf8),
              localName == (entry.isDirectory ? entry.path + "/" : entry.path) || localName == entry.path,
              flags & 0x0008 != 0
                ? ((localCRC == 0 || localCRC == entry.crc32)
                    && (localCompressed == 0 || UInt64(localCompressed) == entry.compressedSize)
                    && (localExpanded == 0 || UInt64(localExpanded) == entry.uncompressedSize))
                : (localCRC == entry.crc32 && UInt64(localCompressed) == entry.compressedSize && UInt64(localExpanded) == entry.uncompressedSize) else {
            throw ManualUpdateError.invalidArchive("local and central ZIP entries do not match")
        }
        if flags & 0x0008 == 0 && method == 0 && flags & 0x0006 != 0 {
            throw ManualUpdateError.invalidArchive("stored entries cannot use deflate option flags")
        }
        try validateExtraFields(in: archive, start: offset + 30 + nameLength, length: extraLength)
        let dataStart = UInt64(offset + 30 + nameLength + extraLength)
        let dataEnd = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !dataEnd.overflow, dataEnd.partialValue <= UInt64(centralOffset) else {
            throw ManualUpdateError.invalidArchive("ZIP entry data overlaps its central directory")
        }
        if flags & 0x0008 != 0 {
            let descriptor = Int(dataEnd.partialValue)
            // Some ZIP writers include the optional descriptor signature; test
            // both layouts because a CRC value can itself equal that signature.
            func matches(at start: Int) -> Bool {
                guard start >= 0, start + 12 <= centralOffset,
                      let crc = try? archive.u32(at: start),
                      let compressed = try? archive.u32(at: start + 4),
                      let expanded = try? archive.u32(at: start + 8) else { return false }
                return crc == entry.crc32 && UInt64(compressed) == entry.compressedSize
                    && UInt64(expanded) == entry.uncompressedSize
            }
            if try archive.u32(at: descriptor) == 0x0807_4b50, matches(at: descriptor + 4) {
                return UInt64(descriptor + 16)
            }
            guard matches(at: descriptor) else {
                throw ManualUpdateError.invalidArchive("ZIP data descriptor does not match central metadata")
            }
            return UInt64(descriptor + 12)
        }
        return dataEnd.partialValue
    }

    private static func validateExtraFields(in data: Data, start: Int, length: Int) throws {
        var cursor = start
        let end = start + length
        guard end <= data.count else { throw ManualUpdateError.invalidArchive("truncated ZIP extra fields") }
        while cursor < end {
            guard cursor + 4 <= end else { throw ManualUpdateError.invalidArchive("malformed ZIP extra fields") }
            let identifier = try data.u16(at: cursor)
            let fieldLength = Int(try data.u16(at: cursor + 2))
            guard cursor + 4 + fieldLength <= end, identifier != 0x0001 else {
                throw ManualUpdateError.invalidArchive("malformed or ZIP64 extra fields are unsupported")
            }
            cursor += 4 + fieldLength
        }
    }

    private static func validatePathHierarchy(_ entries: [String: ManualUpdateArchiveEntry]) throws {
        for entry in entries.values {
            if entry.isSymbolicLink && !isFrameworkPath(entry.components) {
                throw ManualUpdateError.invalidArchive("symbolic links are allowed only inside frameworks")
            }
            for length in 1..<entry.components.count {
                let prefix = entry.components.prefix(length).joined(separator: "/")
                if let ancestor = entries[prefix] {
                    guard !ancestor.isSymbolicLink else {
                        throw ManualUpdateError.invalidArchive("ZIP entries cannot be nested below a symbolic link")
                    }
                    guard ancestor.isDirectory else {
                        throw ManualUpdateError.invalidArchive("a file is also used as a directory")
                    }
                }
            }
        }
    }

    private static func validateArchiveSymlinks(entries: [ManualUpdateArchiveEntry], archive: URL) throws -> [String: String] {
        let symlinkEntries = entries.filter(\.isSymbolicLink)
        guard symlinkEntries.count <= 1_024 else {
            throw ManualUpdateError.invalidArchive("too many framework symbolic links")
        }
        var links: [String: String] = [:]
        for entry in symlinkEntries {
            guard entry.uncompressedSize > 0, entry.uncompressedSize <= 1024,
                  let target = try readSymbolicLink(entry, from: archive),
                  !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
                  !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ManualUpdateError.invalidArchive("invalid framework symbolic link")
            }
            links[entry.path] = target
        }
        for entry in entries where entry.isSymbolicLink {
            let framework = frameworkRoot(entry.components)
            guard let framework else { throw ManualUpdateError.invalidArchive("framework symlink escaped its framework") }
            _ = try resolve(components: entry.components, links: links, frameworkRoot: framework, visiting: [])
        }
        return links
    }

    private static func readSymbolicLink(_ entry: ManualUpdateArchiveEntry, from archive: URL) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ManualUpdateError.invalidArchive("could not inspect framework symlink") }
        var data = Data()
        while data.count <= 1024 {
            let part = output.fileHandleForReading.readData(ofLength: min(256, 1025 - data.count))
            if part.isEmpty { break }
            data.append(part)
        }
        if data.count > 1024 {
            process.terminate()
            process.waitUntilExit()
            throw ManualUpdateError.invalidArchive("framework symlink target is too long")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, UInt64(data.count) == entry.uncompressedSize,
              let target = String(data: data, encoding: .utf8) else {
            throw ManualUpdateError.invalidArchive("could not read framework symlink target")
        }
        return target
    }

    private static func resolve(components: [String], links: [String: String], frameworkRoot: [String], visiting: Set<String>) throws -> [String] {
        var result: [String] = []
        for component in components {
            if component == "." { continue }
            if component == ".." {
                guard result.count > frameworkRoot.count else { throw ManualUpdateError.invalidArchive("framework symlink escapes its bundle") }
                result.removeLast()
                continue
            }
            result.append(component)
            let key = result.joined(separator: "/")
            guard let target = links[key] else { continue }
            guard !visiting.contains(key), isWithin(result, root: frameworkRoot) else {
                throw ManualUpdateError.invalidArchive("framework symlink cycle or escape")
            }
            var nextVisiting = visiting
            nextVisiting.insert(key)
            let replacement = try resolve(components: result.dropLast().map { $0 } + target.split(separator: "/").map(String.init), links: links, frameworkRoot: frameworkRoot, visiting: nextVisiting)
            result = replacement
        }
        guard isWithin(result, root: frameworkRoot) else { throw ManualUpdateError.invalidArchive("framework symlink escapes its bundle") }
        return result
    }

    private static func isFrameworkPath(_ components: [String]) -> Bool { frameworkRoot(components) != nil }

    private static func frameworkRoot(_ components: [String]) -> [String]? {
        guard components.count >= 4, components[0].hasSuffix(".app"), components[1] == "Contents",
              let index = components.firstIndex(where: { $0.hasSuffix(".framework") }), index >= 3,
              components[index - 1] == "Frameworks" else { return nil }
        return Array(components.prefix(index + 1))
    }

    private static func isWithin(_ path: [String], root: [String]) -> Bool {
        path.count >= root.count && Array(path.prefix(root.count)) == root
    }

    private static func validateExtractedSymlinks(appURL: URL, entries: [ManualUpdateArchiveEntry], targets: [String: String]) throws {
        for entry in entries where entry.isSymbolicLink {
            let source = appURL.appendingPathComponent(entry.components.dropFirst().joined(separator: "/"))
            var info = stat()
            guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
                  let target = targets[entry.path] else {
                throw ManualUpdateError.invalidArchive("extracted framework link is invalid")
            }
            let components = entry.components
            guard let root = frameworkRoot(components) else { throw ManualUpdateError.invalidArchive("extracted link is outside a framework") }
            let frameworkURL = appURL.appendingPathComponent(root.dropFirst().joined(separator: "/"), isDirectory: true)
            guard let canonicalFramework = realPath(frameworkURL),
                  let canonicalTarget = realPath(source.deletingLastPathComponent().appendingPathComponent(target)),
                  canonicalTarget == canonicalFramework || canonicalTarget.hasPrefix(canonicalFramework + "/") else {
                throw ManualUpdateError.invalidArchive("framework link target is missing")
            }
        }
    }

    private enum ExtractedNode: Equatable {
        case directory
        case symbolicLink(String)
        case regularFile(size: UInt64, crc32: UInt32)
    }

    private static func validateExtractedTree(
        appURL: URL,
        entries: [ManualUpdateArchiveEntry],
        symlinkTargets: [String: String]
    ) throws {
        var expected: [String: ExtractedNode] = [:]
        for entry in entries {
            let relative = Array(entry.components.dropFirst())
            guard !relative.isEmpty else { continue }
            for length in 1..<relative.count {
                let parent = relative.prefix(length).joined(separator: "/")
                if case .symbolicLink? = expected[parent] {
                    throw ManualUpdateError.invalidArchive("ZIP entry is below a symbolic link")
                }
                expected[parent] = .directory
            }
            let path = relative.joined(separator: "/")
            if entry.isSymbolicLink {
                guard let target = symlinkTargets[entry.path] else { throw ManualUpdateError.invalidArchive("symlink target is missing") }
                expected[path] = .symbolicLink(target)
            } else if entry.isDirectory {
                expected[path] = .directory
            } else {
                expected[path] = .regularFile(size: entry.uncompressedSize, crc32: entry.crc32)
            }
        }

        var actual: [String: ExtractedNode] = [:]
        func walk(_ directory: URL, _ prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                var info = stat()
                guard lstat(child.path, &info) == 0 else { throw ManualUpdateError.invalidArchive("extracted tree changed during validation") }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    actual[relative] = .directory
                    try walk(child, relative)
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: child.path) else {
                        throw ManualUpdateError.invalidArchive("could not read extracted symlink")
                    }
                    actual[relative] = .symbolicLink(target)
                case S_IFREG:
                    let crc = try crc32(of: child, expectedDevice: info.st_dev, expectedInode: info.st_ino)
                    guard info.st_size >= 0 else { throw ManualUpdateError.invalidArchive("invalid extracted file size") }
                    actual[relative] = .regularFile(size: UInt64(info.st_size), crc32: crc)
                default:
                    throw ManualUpdateError.invalidArchive("extraction created a special file")
                }
            }
        }
        try walk(appURL, "")
        guard actual == expected else { throw ManualUpdateError.invalidArchive("extracted app does not match the ZIP manifest") }
    }

    private static func crc32(of url: URL, expectedDevice: dev_t, expectedInode: ino_t) throws -> UInt32 {
        let descriptor = try openReadNoFollow(url)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev == expectedDevice, info.st_ino == expectedInode else {
            throw ManualUpdateError.invalidArchive("extracted file changed during validation")
        }
        var crc: UInt32 = 0xffff_ffff
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.invalidArchive("could not verify extracted file")
            }
            for byte in buffer.prefix(count) {
                crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
            }
        }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        return crc
    }

    private static func openReadNoFollow(_ url: URL) throws -> Int32 {
        let path = url.path
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !path.contains("//"),
              !components.contains("."), !components.contains(".."), let leaf = components.last else {
            throw ManualUpdateError.unsafePath("path is not absolute and canonical")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ManualUpdateError.unsafePath("could not open filesystem root") }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { throw ManualUpdateError.unsafePath("symbolic or invalid path ancestor") }
            directory = next
        }
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        close(directory)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not open file without following links") }
        return descriptor
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func validateNonOverlappingLocalData(_ entries: [ManualUpdateArchiveEntry], centralOffset: Int) throws {
        let sorted = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        var previousEnd: UInt64 = 0
        for entry in sorted {
            let offset = entry.localHeaderOffset
            guard offset >= previousEnd, offset < UInt64(centralOffset) else {
                throw ManualUpdateError.invalidArchive("ZIP local entries overlap")
            }
            guard entry.localRecordEnd <= UInt64(centralOffset) else {
                throw ManualUpdateError.invalidArchive("ZIP local entry is too large")
            }
            previousEnd = entry.localRecordEnd
        }
    }
}

private extension Data {
    func u16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ManualUpdateError.invalidArchive("truncated ZIP") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ManualUpdateError.invalidArchive("truncated ZIP") }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

enum ManualUpdateDigest {
    static func snapshotRegularFile(from sourceURL: URL, to destinationURL: URL, maximumSize: UInt64) throws -> String {
        let source = try openReadNoFollow(sourceURL)
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, UInt64(before.st_size) <= maximumSize else {
            throw ManualUpdateError.invalidArchive("selected item is not a supported ZIP file")
        }
        let destination = try openNewFileNoFollow(destinationURL, mode: 0o600)
        defer { close(destination) }
        var hasher = SHA256()
        var copiedBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.invalidArchive("could not snapshot selected ZIP")
            }
            let nextCount = copiedBytes.addingReportingOverflow(UInt64(count))
            guard !nextCount.overflow,
                  nextCount.partialValue <= UInt64(before.st_size),
                  nextCount.partialValue <= maximumSize else {
                throw ManualUpdateError.invalidArchive("selected ZIP grew beyond its inspected size")
            }
            copiedBytes = nextCount.partialValue
            let bytes = Data(buffer.prefix(count))
            hasher.update(data: bytes)
            var offset = 0
            while offset < count {
                let written = bytes.withUnsafeBytes { raw in
                    Darwin.write(destination, raw.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ManualUpdateError.invalidArchive("could not write private ZIP snapshot")
                }
                offset += written
            }
        }
        var after = stat()
        guard fstat(source, &after) == 0,
              copiedBytes == UInt64(before.st_size),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fsync(destination) == 0 else {
            throw ManualUpdateError.invalidArchive("selected ZIP changed while being snapshotted")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func file(at url: URL) throws -> String {
        let descriptor = try openReadNoFollow(url)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ManualUpdateError.unsafePath("digest source is not a regular file")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("could not read digest source")
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func applicationTree(at root: URL) throws -> String {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: root)
        var hasher = SHA256()
        func frame(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        func record(path: String, kind: UInt8, mode rawMode: mode_t, length rawLength: UInt64, digest: Data) {
            frame(Data(path.utf8))
            frame(Data([kind]))
            var mode = UInt16(rawMode & 0xffff).bigEndian
            frame(withUnsafeBytes(of: &mode) { Data($0) })
            var length = rawLength.bigEndian
            frame(withUnsafeBytes(of: &length) { Data($0) })
            frame(digest)
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ManualUpdateError.invalidApplication("application root changed during inspection")
        }
        frame(Data("NokoCord application tree v1".utf8))
        record(path: "", kind: 1, mode: rootInfo.st_mode, length: 0, digest: Data(SHA256.hash(data: Data())))
        func walk(_ directory: URL, relative: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                var info = stat()
                guard lstat(child.path, &info) == 0 else { throw ManualUpdateError.unsafePath("application tree changed during inspection") }
                let type = info.st_mode & S_IFMT
                let payloadDigest: Data
                var contentLength: UInt64 = 0
                if type == S_IFDIR {
                    payloadDigest = Data(SHA256.hash(data: Data()))
                    try walk(child, relative: childRelative)
                } else if type == S_IFLNK {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                    let targetData = Data(target.utf8)
                    payloadDigest = Data(SHA256.hash(data: targetData))
                    contentLength = UInt64(targetData.count)
                } else if type == S_IFREG {
                    let descriptor = try openReadNoFollow(child)
                    defer { close(descriptor) }
                    var opened = stat()
                    guard fstat(descriptor, &opened) == 0,
                          (opened.st_mode & S_IFMT) == S_IFREG,
                          opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                        throw ManualUpdateError.unsafePath("application tree changed during inspection")
                    }
                    var contentHasher = SHA256()
                    var bytesRead: UInt64 = 0
                    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw ManualUpdateError.unsafePath("could not read application file")
                        }
                        bytesRead += UInt64(count)
                        contentHasher.update(data: Data(buffer.prefix(count)))
                    }
                    var after = stat()
                    guard fstat(descriptor, &after) == 0,
                          opened.st_dev == after.st_dev, opened.st_ino == after.st_ino,
                          opened.st_size == after.st_size, opened.st_mode == after.st_mode,
                          opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                          opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                          opened.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                          opened.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                          opened.st_size >= 0, bytesRead == UInt64(opened.st_size) else {
                        throw ManualUpdateError.unsafePath("application file changed during inspection")
                    }
                    contentLength = bytesRead
                    payloadDigest = Data(contentHasher.finalize())
                } else {
                    throw ManualUpdateError.invalidApplication("application contains a special file")
                }
                // Each record is independently framed: path, type, complete
                // mode bits, content length and SHA-256 payload digest.
                record(
                    path: childRelative,
                    kind: type == S_IFDIR ? 1 : (type == S_IFLNK ? 2 : 3),
                    mode: info.st_mode,
                    length: contentLength,
                    digest: payloadDigest
                )
            }
        }
        try walk(root, relative: "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openReadNoFollow(_ url: URL) throws -> Int32 {
        let path = url.path
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !path.contains("//"),
              !components.contains("."), !components.contains(".."), let leaf = components.last else {
            throw ManualUpdateError.unsafePath("path is not absolute and canonical")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ManualUpdateError.unsafePath("could not open filesystem root") }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { throw ManualUpdateError.unsafePath("symbolic or invalid path ancestor") }
            directory = next
        }
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        close(directory)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not open file without following links") }
        return descriptor
    }

    private static func openNewFileNoFollow(_ url: URL, mode: mode_t) throws -> Int32 {
        let path = url.path
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !path.contains("//"),
              !components.contains("."), !components.contains(".."), let leaf = components.last else {
            throw ManualUpdateError.unsafePath("destination is not absolute and canonical")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ManualUpdateError.unsafePath("could not open filesystem root") }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { throw ManualUpdateError.unsafePath("unsafe destination ancestor") }
            directory = next
        }
        let descriptor = openat(directory, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        close(directory)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not create private snapshot") }
        return descriptor
    }
}
