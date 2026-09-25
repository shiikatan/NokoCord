import Foundation
import Darwin

struct TanTranslationReport: Codable {
    struct Finding: Codable { let code: String; let category: String }
    struct SourceFile: Codable { let path: String; let sha256: String }
    let schemaVersion: Int?
    let translatorVersion: String?
    let compiler: String?
    let entry: String?
    let limitations: [String]?
    let adaptations: [String]?
    let classification: String
    let installable: Bool
    let source: String
    let files: [SourceFile]
    let licenses: [String]
    let findings: [Finding]
}
struct TanTranslationResult: Decodable {
    let report: TanTranslationReport
    let outputs: [String: String]
    func package() throws -> TanPackage {
        let supportedClassification: Bool
        switch report.classification {
        case "Automatic":
            supportedClassification = report.findings.isEmpty && (report.adaptations?.isEmpty ?? true)
        case "Assisted":
            supportedClassification = report.findings.count == 1
                && report.findings[0].code == "lifecycle-timing-adapted"
                && report.findings[0].category == "Assisted"
                && report.adaptations?.count == 1
        default:
            supportedClassification = false
        }
        guard report.installable, supportedClassification,
              let manifestText = outputs["manifest.json"] else { throw TanTranslationError.unsupported }
        let manifest = try JSONDecoder().decode(TanManifest.self, from: Data(manifestText.utf8))
        let package = TanPackage(manifest: manifest, javascript: outputs["main.js"], css: outputs["style.css"], origin: "Translated Tan")
        try package.validate()
        return package
    }
}
enum TanTranslationError: LocalizedError {
    case invalidSource, unavailable, failed, unsupported, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Choose a source folder with index.ts, index.tsx, index.js, or index.jsx and its license. Symbolic links, private configuration, binary files, and oversized folders are not supported."
        case .unavailable: "Tan Translator is unavailable in this build."
        case .failed: "The translation could not be completed within its resource limits. Your source files were not changed."
        case .unsupported: "This source needs changes before it can be installed. Review the conversion report."
        case .cancelled: "Translation cancelled."
        }
    }
}

enum TanTranslationService {
    static func readArchivedReport(_ url: URL) throws -> TanTranslationReport {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw TanTranslationError.invalidSource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let limit = 16 * 1024 * 1024
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= limit else { throw TanTranslationError.invalidSource }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw TanTranslationError.invalidSource }
        }
        struct Archive: Decodable { let report: TanTranslationReport }
        return try JSONDecoder().decode(Archive.self, from: data).report
    }

    static func readSource(_ root: URL) throws -> [String: String] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw TanTranslationError.invalidSource }
        var files: [String: String] = [:], total = 0, entries = 0
        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 5 else { throw TanTranslationError.invalidSource }
            var enumerationFailed = false
            guard let iterator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                throw TanTranslationError.invalidSource
            }
            for case let url as URL in iterator {
                let name = url.lastPathComponent
                if [".git", "node_modules", ".DS_Store"].contains(name) { continue }
                entries += 1
                guard entries <= 256, name.range(of: "^[A-Za-z0-9_. -]+$", options: .regularExpression) != nil,
                      name != ".env", !name.hasPrefix(".env."), !["pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased()) else { throw TanTranslationError.invalidSource }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw TanTranslationError.invalidSource }
                if values.isDirectory == true { try visit(url, prefix: prefix + name + "/", depth: depth + 1) }
                else {
                    guard values.isRegularFile == true, files.count < 128, let size = values.fileSize,
                          size <= 2 * 1024 * 1024 - total else { throw TanTranslationError.invalidSource }
                    // Bound the read itself, including files that grow after metadata inspection.
                    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard descriptor >= 0 else { throw TanTranslationError.invalidSource }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var metadata = stat()
                    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw TanTranslationError.invalidSource }
                    var data = Data()
                    let budget = 2 * 1024 * 1024 - total
                    while let chunk = try handle.read(upToCount: min(65536, budget - data.count + 1)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= budget else { throw TanTranslationError.invalidSource }
                    }
                    total += data.count
                    guard total <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw TanTranslationError.invalidSource }
                    files[prefix + name] = text
                }
            }
            guard !enumerationFailed else { throw TanTranslationError.invalidSource }
        }
        try visit(root, prefix: "", depth: 0)
        guard ["index.ts", "index.tsx", "index.js", "index.jsx"].contains(where: { files[$0] != nil }) else { throw TanTranslationError.invalidSource }
        return files
    }
    static func repositoryPlugins(_ root: URL) throws -> [String] {
        var folder = root
        for component in ["", "src", "plugins"] {
            if !component.isEmpty { folder.appendPathComponent(component) }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw TanTranslationError.invalidSource }
        }
        var failed = false
        guard let iterator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else {
            throw TanTranslationError.invalidSource
        }
        var names: [String] = []
        var count = 0
        for case let url as URL in iterator {
            count += 1
            guard count <= 512 else { throw TanTranslationError.invalidSource }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true,
               url.lastPathComponent.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]*$", options: .regularExpression) != nil {
                let hasEntry = ["index.ts", "index.tsx", "index.js", "index.jsx"].contains { name in
                    guard let entry = try? url.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return entry.isRegularFile == true && entry.isSymbolicLink != true
                }
                if hasEntry { names.append(url.lastPathComponent) }
            }
        }
        guard !failed, !names.isEmpty else { throw TanTranslationError.invalidSource }
        return names.sorted()
    }

    /// Reads shared metadata only from a repository root explicitly selected by the user.
    /// Never discovers or traverses ancestors of a selected plugin folder.
    static func readRepositorySource(_ root: URL, plugin: String) throws -> [String: String] {
        guard plugin.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw TanTranslationError.invalidSource
        }
        func checked(_ components: [String], directory: Bool) throws -> URL {
            var url = root
            for (index, component) in ([""] + components).enumerated() {
                if !component.isEmpty { url.appendPathComponent(component) }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw TanTranslationError.invalidSource }
                if index < components.count || directory {
                    guard values.isDirectory == true else { throw TanTranslationError.invalidSource }
                } else {
                    guard values.isRegularFile == true else { throw TanTranslationError.invalidSource }
                }
            }
            return url
        }
        let folder = try checked(["src", "plugins", plugin], directory: true)
        var files = try readSource(folder)
        guard !files.keys.contains(where: { $0 == "_repository" || $0.hasPrefix("_repository/") }) else {
            throw TanTranslationError.invalidSource
        }
        for (components, name) in [(["LICENSE"], "LICENSE"), (["src", "utils", "constants.ts"], "constants.ts")] {
            let url = try checked(components, directory: false)
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw TanTranslationError.invalidSource }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw TanTranslationError.invalidSource }
            let remaining = 2 * 1024 * 1024 - files.values.reduce(0) { $0 + $1.utf8.count }
            guard files.count < 128, remaining >= 0 else { throw TanTranslationError.invalidSource }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(65536, remaining - data.count + 1)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= remaining else { throw TanTranslationError.invalidSource }
            }
            guard let text = String(data: data, encoding: .utf8) else { throw TanTranslationError.invalidSource }
            files["_repository/" + name] = text
        }
        return files
    }
    static func translate(files: [String: String], useDocumentReadyTiming: Bool = false, executable: URL? = nil) async throws -> TanTranslationResult {
        let helper = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TanTranslator")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw TanTranslationError.unavailable }
        let runner = TanTranslationProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.run(files: files, useDocumentReadyTiming: useDocumentReadyTiming, executable: helper)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { runner.cancel() }
    }
}

private final class TanTranslationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
    func run(files: [String: String], useDocumentReadyTiming: Bool, executable: URL) throws -> TanTranslationResult {
        let entry = ["index.ts", "index.tsx", "index.js", "index.jsx"].first { files[$0] != nil }
        guard let entry, files.count <= 128, files.values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw TanTranslationError.invalidSource }
        var request: [String: Any] = ["files": files, "entry": entry, "id": "imported." + UUID().uuidString.lowercased()]
        if useDocumentReadyTiming { request["lifecycleTiming"] = "document-ready" }
        let input = try JSONSerialization.data(withJSONObject: request)
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.standardInput = stdin; child.standardOutput = stdout
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardError = FileHandle.nullDevice
        // The fixed helper loads its bundled compiler and receives source over a pipe.
        // No source path, credential, bookmark or environment secret is passed.
        child.environment = [:]
        lock.lock()
        guard !cancelled else { lock.unlock(); throw TanTranslationError.cancelled }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw TanTranslationError.unavailable }
        lock.unlock()
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        defer {
            deadline.cancel()
            try? stdin.fileHandleForWriting.close(); try? stdout.fileHandleForReading.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            lock.lock(); process = nil; lock.unlock()
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            var output = Data()
            while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                output.append(chunk)
                guard output.count <= 16 * 1024 * 1024 else { throw TanTranslationError.failed }
            }
            child.waitUntilExit()
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            guard !wasCancelled else { throw TanTranslationError.cancelled }
            guard child.terminationStatus == 0 else { throw TanTranslationError.failed }
            return try JSONDecoder().decode(TanTranslationResult.self, from: output)
        } catch let error as TanTranslationError { throw error }
        catch { throw TanTranslationError.failed }
    }
}
