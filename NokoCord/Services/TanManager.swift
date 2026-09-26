import Foundation
import Observation

@MainActor @Observable
final class TanManager {
    private(set) var installed: [TanPackage] = []
    private(set) var enabledIDs: Set<String> = []
    private(set) var safeMode = false
    private(set) var developerMode = false
    private(set) var diagnostics: [TanDiagnostic] = []
    private(set) var error: String?
    var reloadRequired = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var enableLog: [String] = []
    @ObservationIgnored private var failures: [String: Int] = [:]
    private struct State: Codable {
        var version = 1
        var enabled: [String]
        var safeMode: Bool
        var developerMode: Bool
        var enableLog: [String]
    }
    init(root: URL? = nil, launchSafeMode: Bool = ProcessInfo.processInfo.arguments.contains("--safe-mode")) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NokoCord/Tans", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: self.root.path) {
                guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TanError.invalid("Invalid Tan storage") }
                let files = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                for url in files.filter({ $0.lastPathComponent.hasSuffix(".tan.json") }).prefix(64) {
                    do {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { continue }
                        let package = try JSONDecoder().decode(TanPackage.self, from: Data(contentsOf: url))
                        try package.validate()
                        guard url.lastPathComponent == package.id + ".tan.json", !installed.contains(where: { $0.id == package.id }) else { continue }
                        installed.append(package)
                    } catch { self.error = "Some Tan packages could not be loaded." }
                }
                let stateURL = self.root.appendingPathComponent("state.json")
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    let values = try stateURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 128 * 1024 else { throw TanError.invalid("Invalid Tan state") }
                    let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
                    guard state.version == 1 else { throw TanError.invalid("Unsupported Tan state") }
                    enabledIDs = Set(state.enabled).intersection(Set(installed.map(\.id)))
                    safeMode = state.safeMode; developerMode = state.developerMode
                    enableLog = Array(state.enableLog.filter { enabledIDs.contains($0) }.suffix(64))
                }
            }
        } catch { safeMode = true; self.error = "Tan storage could not be restored. Safe Mode is on." }
        if launchSafeMode { safeMode = true }
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }
    var active: [TanPackage] { safeMode ? [] : installed.filter { enabledIDs.contains($0.id) } }
    var availableOriginals: [TanPackage] { TanPackage.originals.filter { original in !installed.contains { $0.id == original.id } } }
    func install(_ package: TanPackage) throws {
        try package.validate()
        guard installed.count < 64 || installed.contains(where: { $0.id == package.id }) else { throw TanError.invalid("The Tan limit is 64 packages") }
        // An import never silently replaces installed code or inherits its grants.
        guard !installed.contains(where: { $0.id == package.id }) else { throw TanError.invalid("This Tan is already installed") }
        try prepareStorage()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let url = root.appendingPathComponent(package.id + ".tan.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw TanError.invalid("A Tan package already exists at this location") }
        try encoder.encode(package).write(to: url, options: [.atomic])
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        installed.append(package)
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        // Installation stays disabled; no state mutation is necessary here.
        onChange?()
    }

    /// Creates and installs a custom CSS theme as an active Tan with live hot-reloading.
    @discardableResult
    func importCustomCSSTheme(name: String, css: String) throws -> TanPackage {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw TanError.invalid("Theme name cannot be empty") }
        let slug = cleanName.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        let shortSlug = slug.isEmpty ? "custom" : String(slug.prefix(30))
        let id = "theme." + shortSlug + "." + String(UUID().uuidString.prefix(6).lowercased())
        let manifest = TanManifest(
            schemaVersion: 1,
            id: id,
            name: cleanName,
            version: "1.0.0",
            description: "Custom CSS theme for Discord",
            authors: ["User"],
            target: .css,
            entry: nil,
            stylesheet: "theme.css",
            capabilities: [],
            requiresReload: false,
            source: nil,
            license: "MIT"
        )
        let package = TanPackage(
            manifest: manifest,
            javascript: nil,
            css: css,
            origin: "Custom Theme"
        )
        try install(package)
        setEnabled(id, true)
        return package
    }
    func availableOriginalUpdate(_ package: TanPackage) -> TanPackage? {
        guard ["Noko Original", "Noko-Tan"].contains(package.origin) else { return nil }
        return TanPackage.originals.first { $0.id == package.id && $0.contentHash != package.contentHash }
    }
    func updateOriginal(_ id: String) throws {
        guard let package = installed.first(where: { $0.id == id }), let update = availableOriginalUpdate(package) else { return }
        try replace(update)
    }
    func replaceFromLocalFolder(_ package: TanPackage) throws {
        guard developerMode else { throw TanError.invalid("Enable Developer Mode to reload local code") }
        try replace(package)
    }
    private func replace(_ package: TanPackage) throws {
        try package.validate()
        guard let index = installed.firstIndex(where: { $0.id == package.id }) else {
            throw TanError.invalid("Enable Developer Mode and select an installed Tan")
        }
        // A new content hash always requires another explicit enable decision.
        let previous = enabledIDs
        enabledIDs.remove(package.id)
        do { try saveState() } catch { enabledIDs = previous; throw error }
        onChange?()
        let url = root.appendingPathComponent(package.id + ".tan.json")
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TanError.invalid("Invalid Tan storage") }
        try JSONEncoder().encode(package).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        installed[index] = package
        onChange?()
    }
    func installTranslation(_ result: TanTranslationResult, source: [String: String]) throws {
        let package = try result.package()
        guard !installed.contains(where: { $0.id == package.id }), source.count <= 128,
              source.values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw TanError.invalid("Invalid translation archive") }
        struct Archive: Encodable { let report: TanTranslationReport; let files: [String: String] }
        let data = try JSONEncoder().encode(Archive(report: result.report, files: source))
        guard data.count <= 16 * 1024 * 1024 else { throw TanError.invalid("Translation archive is too large") }
        try prepareStorage()
        let archive = root.appendingPathComponent(package.id + ".source.json")
        guard !FileManager.default.fileExists(atPath: archive.path) else { throw TanError.invalid("A source archive already exists") }
        try data.write(to: archive, options: [.atomic])
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            try install(package)
        }
        catch { try? FileManager.default.removeItem(at: archive); throw error }
    }
    func translationReport(for id: String) async throws -> TanTranslationReport? {
        guard installed.contains(where: { $0.id == id && $0.origin == "Translated Tan" }) else { return nil }
        let url = root.appendingPathComponent(id + ".source.json")
        return try await Task.detached(priority: .utility) {
            try TanTranslationService.readArchivedReport(url)
        }.value
    }
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard installed.contains(where: { $0.id == id }) else { return }
        let previous = enabledIDs
        if enabled { enabledIDs.insert(id); enableLog.append(id); enableLog = Array(enableLog.suffix(64)); failures[id] = 0 }
        else { enabledIDs.remove(id) }
        do { try saveState(); onChange?() }
        catch { enabledIDs = previous; self.error = "The Tan selection could not be saved." }
    }
    func setSafeMode(_ enabled: Bool) {
        let previous = safeMode; safeMode = enabled
        do { try saveState(); onChange?() }
        catch { safeMode = previous; self.error = "Safe Mode could not be saved." }
    }
    func setDeveloperMode(_ enabled: Bool) {
        let previous = developerMode; developerMode = enabled
        do { try saveState(); onChange?() }
        catch { developerMode = previous; self.error = "Developer Mode could not be saved." }
    }
    func uninstall(_ id: String) throws {
        guard installed.contains(where: { $0.id == id }) else { return }
        let previous = enabledIDs
        enabledIDs.remove(id)
        do { try saveState() } catch { enabledIDs = previous; throw error }
        onChange?() // Stop the disabled package even if removing its file fails.
        // Keep the package visible and retryable if archive removal fails.
        let archive = root.appendingPathComponent(id + ".source.json")
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id + ".tan.json"))
        installed.removeAll { $0.id == id }
        onChange?()
    }
    func record(_ id: String, event: TanDiagnostic.Event) {
        guard installed.contains(where: { $0.id == id }) else { return }
        diagnostics.append(TanDiagnostic(tanID: id, event: event))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
        if event == .failed {
            failures[id, default: 0] += 1
            if failures[id, default: 0] >= 3 { setEnabled(id, false); error = "A repeatedly failing Tan was disabled." }
        }
    }
    func dismissError() { error = nil }
    func clearConsole() { diagnostics.removeAll() }
    private func prepareStorage() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TanError.invalid("Invalid Tan storage") }
    }
    private func saveState() throws {
        try prepareStorage()
        let state = State(enabled: enabledIDs.sorted(), safeMode: safeMode, developerMode: developerMode, enableLog: enableLog)
        let url = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw TanError.invalid("Invalid Tan state") }
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
