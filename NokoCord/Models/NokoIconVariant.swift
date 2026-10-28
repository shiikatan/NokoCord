import CryptoKit
import Foundation
import Darwin

enum NokoAppIcon: String, CaseIterable, Identifiable, Codable, Sendable {
    case nokocord, maolist
    var id: String { rawValue }
    var label: String { self == .nokocord ? "NokoCord" : "MaoList" }
    var assetName: String { self == .nokocord ? "MaomaoAppIcon" : "MaoListAppIcon" }
    static func installed(in bundle: Bundle = .main) -> Self {
        bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "MaoListAppIcon" ? .maolist : .nokocord
    }
}

enum NokoIconVariantError: LocalizedError {
    case invalid, differentBuild, changedApplication
    var errorDescription: String? {
        switch self {
        case .invalid: "The icon switching files are invalid. Nothing was changed."
        case .differentBuild: "The icon switching files do not match this app version. Nothing was changed."
        case .changedApplication: "This app does not match the signed icon build. Nothing was changed."
        }
    }
}

struct NokoIconFile: Codable, Equatable, Sendable {
    let kind: String
    let mode: Int
    let size: Int?
    let sha256: String?
    let link: String?
}

/// Both signed variants share every resource and executable instruction. Only
/// native icon metadata and existing code-signature bytes may be replaced.
struct NokoIconVariantPackage: Codable, Sendable {
    struct Chunk: Codable, Sendable { let offset: Int; let bytes: Data }
    struct Change: Codable, Sendable {
        let path: String
        let toMaoList: [Chunk]
        let toNokoCord: [Chunk]
    }
    static let maximumSize = 16 * 1024 * 1024
    static let allowedChanges: Set<String> = ["Contents/Info.plist", "Contents/MacOS/NokoCord", "Contents/_CodeSignature/CodeResources"]
    let schemaVersion: Int
    let bundleIdentifier: String
    let version: String
    let build: String
    let unsignedExecutableSHA256: String
    let variants: [String: [String: NokoIconFile]]
    let changes: [Change]

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumSize else { throw NokoIconVariantError.invalid }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.validate()
        return package
    }

    func validate() throws {
        guard schemaVersion == 1, bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              (try? ManualUpdateVersion(version))?.description == version,
              (try? ManualUpdateBuild(build))?.description == build,
              Self.isHash(unsignedExecutableSHA256), Set(variants.keys) == Set(NokoAppIcon.allCases.map(\.rawValue)),
              let noko = variants["nokocord"], let mao = variants["maolist"],
              !noko.isEmpty, noko.count <= 4096, Set(noko.keys) == Set(mao.keys),
              Set(changes.map(\.path)).count == changes.count else { throw NokoIconVariantError.invalid }
        for files in variants.values { for (path, entry) in files {
            guard Self.validPath(path), (0...0o777).contains(entry.mode) else { throw NokoIconVariantError.invalid }
            switch entry.kind {
            case "file":
                guard let size = entry.size, size >= 0, size <= 768 * 1024 * 1024,
                      entry.sha256.map(Self.isHash) == true, entry.link == nil else { throw NokoIconVariantError.invalid }
            case "directory":
                guard entry.size == nil, entry.sha256 == nil, entry.link == nil else { throw NokoIconVariantError.invalid }
            case "symlink":
                guard let link = entry.link, !link.isEmpty, link.utf8.count <= 1024,
                      !link.hasPrefix("/"), !link.unicodeScalars.contains(where: { $0.value < 32 }),
                      entry.size == nil, entry.sha256 == nil else { throw NokoIconVariantError.invalid }
            default: throw NokoIconVariantError.invalid
            }
        } }
        let different = Set(noko.keys.filter { noko[$0] != mao[$0] })
        guard different == Set(changes.map(\.path)), different.isSubset(of: Self.allowedChanges) else { throw NokoIconVariantError.invalid }
        for change in changes {
            guard let a = noko[change.path], let b = mao[change.path], a.kind == "file", b.kind == "file",
                  a.mode == b.mode, let aSize = a.size, let bSize = b.size,
                  aSize <= 128 * 1024 * 1024, bSize <= 128 * 1024 * 1024 else { throw NokoIconVariantError.invalid }
            try Self.validateChunks(change.toMaoList, size: bSize)
            try Self.validateChunks(change.toNokoCord, size: aSize)
        }
    }

    private static func validateChunks(_ chunks: [Chunk], size: Int) throws {
        guard chunks.count <= 4096 else { throw NokoIconVariantError.invalid }
        var end = 0, total = 0
        for chunk in chunks {
            guard !chunk.bytes.isEmpty, chunk.offset >= end, chunk.bytes.count <= maximumSize,
                  chunk.offset <= size - chunk.bytes.count else { throw NokoIconVariantError.invalid }
            end = chunk.offset + chunk.bytes.count
            total += chunk.bytes.count
            guard total <= maximumSize else { throw NokoIconVariantError.invalid }
        }
    }

    static func validPath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 1024 && pieces.first == "Contents" && pieces.count <= 32
            && pieces.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func files(in app: URL) throws -> [String: NokoIconFile] {
        var result: [String: NokoIconFile] = [:]
        func walk(_ directory: URL, prefix: String) throws {
            try Task.checkCancellation()
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + url.lastPathComponent
                guard validPath(path), result.count < 4096 else { throw NokoIconVariantError.invalid }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw NokoIconVariantError.changedApplication }
                let mode = Int(info.st_mode & 0o777)
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    result[path] = NokoIconFile(kind: "directory", mode: mode, size: nil, sha256: nil, link: nil)
                    try walk(url, prefix: path + "/")
                case S_IFREG:
                    guard info.st_size >= 0, info.st_size <= 768 * 1024 * 1024 else { throw NokoIconVariantError.changedApplication }
                    result[path] = NokoIconFile(kind: "file", mode: mode, size: Int(info.st_size), sha256: try ManualUpdateDigest.file(at: url), link: nil)
                case S_IFLNK:
                    result[path] = NokoIconFile(kind: "symlink", mode: mode, size: nil, sha256: nil, link: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                default: throw NokoIconVariantError.changedApplication
                }
            }
        }
        try walk(app, prefix: "")
        return result
    }

    /// Reconstruct only in a new owned staging folder. Never patch the running app.
    func reconstruct(from source: URL, to target: URL, icon: NokoAppIcon) throws {
        try validate()
        let metadata = try ManualUpdateApplicationMetadata.read(from: source)
        guard metadata.marketingVersion.description == version, metadata.build.description == build else { throw NokoIconVariantError.differentBuild }
        let current = try Self.files(in: source)
        guard let sourceIcon = NokoAppIcon.allCases.first(where: { variants[$0.rawValue] == current }), sourceIcon != icon,
              try Self.unsignedExecutableDigest(source.appendingPathComponent("Contents/MacOS/NokoCord")) == unsignedExecutableSHA256,
              let expected = variants[icon.rawValue] else { throw NokoIconVariantError.changedApplication }
        try MaomaoDataPaths.validateNoSymlinkComponents(at: target)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NokoIconVariantError.invalid }
        // FileManager uses a fresh tree, retaining framework symlinks. Staging
        // is removed after the preserving updater handoff or on any failure.
        try FileManager.default.copyItem(at: source, to: target)
        do {
            for change in changes {
                try Task.checkCancellation()
                let url = target.appendingPathComponent(change.path)
                var sourceInfo = stat(), targetInfo = stat()
                guard lstat(source.appendingPathComponent(change.path).path, &sourceInfo) == 0,
                      lstat(url.path, &targetInfo) == 0, (targetInfo.st_mode & S_IFMT) == S_IFREG,
                      sourceInfo.st_dev != targetInfo.st_dev || sourceInfo.st_ino != targetInfo.st_ino,
                      let size = expected[change.path]?.size else { throw NokoIconVariantError.invalid }
                let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw NokoIconVariantError.invalid }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    for chunk in icon == .maolist ? change.toMaoList : change.toNokoCord {
                        try file.seek(toOffset: UInt64(chunk.offset)); try file.write(contentsOf: chunk.bytes)
                    }
                    try file.truncate(atOffset: UInt64(size)); try file.synchronize(); try file.close()
                } catch { try? file.close(); throw error }
            }
            guard try Self.files(in: target) == expected else { throw NokoIconVariantError.invalid }
            try Self.validateNativePair(source, target)
        } catch {
            try? ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(target)
            throw error
        }
    }

    static func validateNativePair(_ source: URL, _ target: URL) throws {
        func info(_ app: URL) throws -> [String: Any] {
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw NokoIconVariantError.invalid }
            return value
        }
        var a = try info(source), b = try info(target)
        let names = Set(["MaomaoAppIcon", "MaoListAppIcon"])
        guard let left = a["CFBundleIconName"] as? String, let right = b["CFBundleIconName"] as? String,
              names.contains(left), names.contains(right), left != right,
              a["CFBundleIconFile"] as? String == left, b["CFBundleIconFile"] as? String == right else { throw NokoIconVariantError.invalid }
        for key in ["CFBundleIconName", "CFBundleIconFile"] { a.removeValue(forKey: key); b.removeValue(forKey: key) }
        guard NSDictionary(dictionary: a).isEqual(to: b) else { throw NokoIconVariantError.invalid }
        let first = try files(in: source), second = try files(in: target)
        guard Set(first.keys) == Set(second.keys),
              first.keys.allSatisfy({ path in
                  if first[path] == second[path] { return true }
                  return allowedChanges.contains(path) && first[path]?.kind == "file" && second[path]?.kind == "file" && first[path]?.mode == second[path]?.mode
              }),
              try unsignedExecutableDigest(source.appendingPathComponent("Contents/MacOS/NokoCord")) == unsignedExecutableDigest(target.appendingPathComponent("Contents/MacOS/NokoCord")) else { throw NokoIconVariantError.invalid }
    }

    static func unsignedExecutableDigest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 32, data.count <= 128 * 1024 * 1024 else { throw NokoIconVariantError.invalid }
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw NokoIconVariantError.invalid }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        guard try word(0) == 0xFEEDFACF else { throw NokoIconVariantError.invalid }
        let count = Int(try word(16)), bytes = Int(try word(20))
        guard count <= 1024, bytes <= data.count - 32 else { throw NokoIconVariantError.invalid }
        var cursor = 32, signature: (Int, Int)?, clear: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor <= 32 + bytes - 8 else { throw NokoIconVariantError.invalid }
            let command = try word(cursor), size = Int(try word(cursor + 4))
            guard size >= 8, size <= 32 + bytes - cursor else { throw NokoIconVariantError.invalid }
            if command == 0x1D {
                guard signature == nil, size == 16 else { throw NokoIconVariantError.invalid }
                signature = (Int(try word(cursor + 8)), Int(try word(cursor + 12)))
                clear.append(cursor + 8..<cursor + 16)
            } else if command == 0x19, size >= 72,
                      String(data: data[cursor + 8..<cursor + 24].prefix(while: { $0 != 0 }), encoding: .utf8) == "__LINKEDIT" {
                clear += [cursor + 32..<cursor + 40, cursor + 48..<cursor + 56]
            }
            cursor += size
        }
        guard let (offset, size) = signature, offset >= 32 + bytes, size <= data.count, offset == data.count - size else { throw NokoIconVariantError.invalid }
        var normalized = Data(data.prefix(offset))
        for range in clear { normalized.replaceSubrange(range, with: repeatElement(UInt8(0), count: range.count)) }
        return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
    }
}
