import Foundation
import CryptoKit
import Darwin

enum TanTarget: String, Codable, CaseIterable { case css, isolated, page }
enum TanCapability: String, Codable { case appearanceRead = "appearance.read" }

struct TanManifest: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    let id: String
    let name: String
    let version: String
    let description: String
    let authors: [String]
    let target: TanTarget
    var entry: String?
    var stylesheet: String?
    var capabilities: [TanCapability] = []
    var requiresReload = false
    var source: String?
    var license: String?

    func validate() throws {
        func safeDisplayText(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard schemaVersion == 1 else { throw TanError.invalid("Unsupported manifest version") }
        guard id.range(of: "^[a-z0-9][a-z0-9.-]{2,79}$", options: .regularExpression) != nil,
              !id.contains(".."), !id.hasSuffix(".") else { throw TanError.invalid("Invalid Tan identifier") }
        guard safeDisplayText(name), name.count <= 80, description.count <= 1000,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              !authors.isEmpty, authors.count <= 8,
              authors.allSatisfy({ safeDisplayText($0) && $0.count <= 100 }) else {
            throw TanError.invalid("Invalid Tan metadata")
        }
        for file in [entry, stylesheet].compactMap({ $0 }) {
            guard file.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$", options: .regularExpression) != nil,
                  !file.contains("..") else { throw TanError.invalid("Tan files must be local filenames") }
        }
        guard target == .css ? (entry == nil && stylesheet?.hasSuffix(".css") == true) : entry?.hasSuffix(".js") == true else {
            throw TanError.invalid("Missing Tan entry file")
        }
        if let stylesheet, !stylesheet.hasSuffix(".css") { throw TanError.invalid("Stylesheets must be CSS") }
        guard Set(capabilities).count == capabilities.count,
              target == .isolated || capabilities.isEmpty else { throw TanError.invalid("Native capabilities require an isolated Tan") }
        if let source {
            guard let url = URL(string: source), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil else { throw TanError.invalid("Invalid Tan source URL") }
        }
    }
}

struct TanPackage: Codable, Equatable, Identifiable {
    let manifest: TanManifest
    let javascript: String?
    let css: String?
    let origin: String
    var id: String { manifest.id }
    var contentHash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        try manifest.validate()
        guard origin.count <= 200, (javascript?.utf8.count ?? 0) + (css?.utf8.count ?? 0) <= 512 * 1024,
              manifest.target == .css ? javascript == nil : javascript != nil,
              manifest.stylesheet == nil || css != nil else { throw TanError.invalid("Invalid or oversized Tan content") }
    }
    static func load(folder: URL) throws -> TanPackage {
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw TanError.invalid("Invalid Tan package folder") }
        defer { close(directory) }
        func read(_ filename: String, limit: Int) throws -> Data {
            let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw TanError.invalid("Missing or invalid Tan file") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size <= limit else {
                throw TanError.invalid("Invalid or oversized Tan file")
            }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= limit else { throw TanError.invalid("Oversized Tan file") }
            }
            return data
        }
        let manifest = try JSONDecoder().decode(TanManifest.self, from: read("manifest.json", limit: 16 * 1024))
        try manifest.validate()
        func content(_ filename: String?) throws -> String? {
            guard let filename else { return nil }
            guard let text = String(data: try read(filename, limit: 512 * 1024), encoding: .utf8) else { throw TanError.invalid("Tan source must be UTF-8") }
            return text
        }
        let result = TanPackage(manifest: manifest, javascript: try content(manifest.entry), css: try content(manifest.stylesheet), origin: "Local package")
        try result.validate(); return result
    }
}

enum TanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct TanDiagnostic: Identifiable {
    let id = UUID()
    let tanID: String
    let event: Event
    let date = Date()
    enum Event: String { case started, stopped, failed, rejected }
}

struct TanBridgeRequest: Decodable {
    let type: String
    let capability: String?
    let state: String?
    static func parse(_ body: [String: Any]) -> TanBridgeRequest? {
        guard let type = body["type"] as? String else { return nil }
        if type == "status", Set(body.keys) == ["type", "state"],
           let state = body["state"] as? String, ["started", "stopped", "failed"].contains(state) {
            return TanBridgeRequest(type: type, capability: nil, state: state)
        }
        if type == "capability", Set(body.keys) == ["type", "capability"],
           let capability = body["capability"] as? String, capability == TanCapability.appearanceRead.rawValue {
            return TanBridgeRequest(type: type, capability: capability, state: nil)
        }
        return nil
    }
    func permits(_ manifest: TanManifest) -> Bool {
        guard manifest.target == .isolated else { return false }
        return type == "capability" && capability == TanCapability.appearanceRead.rawValue && manifest.capabilities.contains(.appearanceRead)
    }
}

// Bundled official Noko-Tans are defined in TanOriginals.swift


extension TanManifest {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, description, authors, target, entry, stylesheet, capabilities, requiresReload, source, license
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        authors = try c.decode([String].self, forKey: .authors)
        target = try c.decode(TanTarget.self, forKey: .target)
        entry = try c.decodeIfPresent(String.self, forKey: .entry)
        stylesheet = try c.decodeIfPresent(String.self, forKey: .stylesheet)
        capabilities = try c.decodeIfPresent([TanCapability].self, forKey: .capabilities) ?? []
        requiresReload = try c.decodeIfPresent(Bool.self, forKey: .requiresReload) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        license = try c.decodeIfPresent(String.self, forKey: .license)
    }
}
