import Foundation
import Observation

enum TanImportDecision {
    case install
    case update(TanPackage)
    case reinstall(TanPackage)
    case downgrade(TanPackage)
    case similarName(TanPackage)
}

@MainActor @Observable
final class TanManager {
    private(set) var installed: [TanPackage] = []
    private(set) var enabledIDs: Set<String> = []
    private(set) var safeMode = false
    private(set) var error: String?
    var reloadRequired = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let usesEditionScopedStorage: Bool
    @ObservationIgnored private let launchSafeMode: Bool
    @ObservationIgnored private var changeObservers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var enableLog: [String] = []
    @ObservationIgnored private var failures: [String: Int] = [:]
    private struct State: Codable {
        var version = 1
        var enabled: [String]
        var safeMode: Bool
        var enableLog: [String]
    }
    init(root: URL? = nil, launchSafeMode: Bool = ProcessInfo.processInfo.arguments.contains("--safe-mode")) {
        let editionPaths = try? MaomaoDataPaths.current()
        usesEditionScopedStorage = root == nil && editionPaths != nil
        self.launchSafeMode = launchSafeMode
        self.root = root ?? editionPaths?.tanStorage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NokoCord/Tans", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: self.root.path) {
                if usesEditionScopedStorage {
                    try MaomaoDataPaths.validateNoSymlinkComponents(at: self.root)
                } else {
                    guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TanError.invalid("Invalid Tan storage") }
                }
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
                    safeMode = state.safeMode
                    enableLog = Array(state.enableLog.filter { enabledIDs.contains($0) }.suffix(64))
                }
            }
        } catch { safeMode = true; self.error = "Tan storage could not be restored. Safe Mode is on." }
        if launchSafeMode { safeMode = true }
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    /// Reloads validated storage after an explicit updater-assisted Tan import.
    /// The new in-memory snapshot is published atomically to observers so
    /// enabled packages and Safe Mode take effect without restarting NokoCord.
    func reloadFromStorage() throws {
        let refreshed = TanManager(root: usesEditionScopedStorage ? nil : root, launchSafeMode: launchSafeMode)
        if let error = refreshed.error { throw TanError.invalid(error) }
        installed = refreshed.installed
        enabledIDs = refreshed.enabledIDs
        safeMode = refreshed.safeMode
        error = refreshed.error
        enableLog = refreshed.enableLog
        failures.removeAll()
        notifyChanged()
    }
    var active: [TanPackage] { safeMode ? [] : installed.filter { enabledIDs.contains($0.id) } }
    var scriptActive: [TanPackage] { active.filter { $0.manifest.target != .native } }
    var availableOriginals: [TanPackage] { TanPackage.originals.filter { original in !installed.contains { $0.id == original.id } } }
    @discardableResult
    func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        changeObservers[id] = observer
        return id
    }
    func removeChangeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }
    private func notifyChanged() {
        onChange?()
        for observer in Array(changeObservers.values) { observer() }
    }
    func importDecision(for package: TanPackage) throws -> TanImportDecision {
        try package.validate()
        guard package.manifest.target != .native else { throw TanError.invalid("Native Tans cannot be imported") }
        if let existing = installed.first(where: { $0.id == package.id }) {
            switch package.manifest.version.compare(existing.manifest.version, options: .numeric) {
            case .orderedDescending: return .update(existing)
            case .orderedAscending: return .downgrade(existing)
            case .orderedSame: return .reinstall(existing)
            }
        }
        func normalizedName(_ name: String) -> String {
            String(name.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let normalized = normalizedName(package.manifest.name)
        if !normalized.isEmpty,
           let existing = installed.first(where: { normalizedName($0.manifest.name) == normalized }) {
            return .similarName(existing)
        }
        return .install
    }
    func install(_ package: TanPackage) throws {
        try package.validate()
        if package.manifest.target == .native {
            guard TanPackage.originals.contains(where: {
                $0.id == package.id && $0.origin == "Noko Original" && $0.contentHash == package.contentHash
            }) else { throw TanError.invalid("Only bundled native Tans can be installed") }
        }
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
        // A new installation is disabled, so the browser scripts are unchanged.
    }
    func availableOriginalUpdate(_ package: TanPackage) -> TanPackage? {
        let official = ["Noko Original", "Noko-Tan"].contains(package.origin)
        return TanPackage.originals.first {
            guard $0.id == package.id else { return false }
            let order = $0.manifest.version.compare(package.manifest.version, options: .numeric)
            // A local package with the same ID may explicitly opt into a newer
            // bundled release, but cannot silently inherit official trust.
            return official ? (order != .orderedAscending && $0.contentHash != package.contentHash)
                : order == .orderedDescending
        }
    }
    func updateOriginal(_ id: String) throws {
        guard let package = installed.first(where: { $0.id == id }), let update = availableOriginalUpdate(package) else { return }
        try replace(update, allowBundledNative: true)
    }
    func replaceInstalled(_ package: TanPackage) throws { try replace(package, allowBundledNative: false) }
    private func replace(_ package: TanPackage, allowBundledNative: Bool) throws {
        try package.validate()
        if package.manifest.target == .native {
            guard allowBundledNative, TanPackage.originals.contains(where: {
                $0.id == package.id && $0.origin == "Noko Original" && $0.contentHash == package.contentHash
            }) else { throw TanError.invalid("Native Tans cannot be replaced from an import") }
        }
        guard let index = installed.firstIndex(where: { $0.id == package.id }) else {
            throw TanError.invalid("This Tan is not installed")
        }
        try prepareStorage()
        let old = installed[index]
        let sameOfficialOrigin = ["Noko Original", "Noko-Tan"].contains(old.origin)
            && ["Noko Original", "Noko-Tan"].contains(package.origin)
        let trustedIdentityUnchanged = old.manifest.authors == package.manifest.authors
            && old.manifest.source == package.manifest.source
            && old.manifest.target == package.manifest.target
            && old.manifest.capabilities == package.manifest.capabilities
            && (old.origin == package.origin || sameOfficialOrigin)
        let downgrade = package.manifest.version.compare(old.manifest.version, options: .numeric) == .orderedAscending
        let disable = !trustedIdentityUnchanged || downgrade
        let wasEnabled = enabledIDs.contains(package.id)
        let fileManager = FileManager.default
        let url = root.appendingPathComponent(package.id + ".tan.json")
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw TanError.invalid("Invalid Tan storage")
        }
        let temporary = root.appendingPathComponent(".tan-replacement-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: temporary) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(package).write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let previous = enabledIDs
        if disable {
            enabledIDs.remove(package.id)
            do { try saveState() } catch { enabledIDs = previous; throw error }
        }
        do { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) }
        catch {
            if disable { enabledIDs = previous; try? saveState() }
            throw error
        }
        installed[index] = package
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        if package.origin != "Translated Tan" {
            let staleArchive = root.appendingPathComponent(package.id + ".source.json")
            if fileManager.fileExists(atPath: staleArchive.path) { try? fileManager.removeItem(at: staleArchive) }
        }
        if wasEnabled { notifyChanged() }
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
        do { try saveState(); notifyChanged() }
        catch { enabledIDs = previous; self.error = "The Tan selection could not be saved." }
    }
    func setSafeMode(_ enabled: Bool) {
        let previous = safeMode; safeMode = enabled
        do { try saveState(); notifyChanged() }
        catch { safeMode = previous; self.error = "Safe Mode could not be saved." }
    }
    func uninstall(_ id: String) throws {
        guard installed.contains(where: { $0.id == id }) else { return }
        let previous = enabledIDs
        enabledIDs.remove(id)
        do { try saveState() } catch { enabledIDs = previous; throw error }
        notifyChanged() // Stop the disabled package even if removing its file fails.
        // Keep the package visible and retryable if archive removal fails.
        let archive = root.appendingPathComponent(id + ".source.json")
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id + ".tan.json"))
        installed.removeAll { $0.id == id }
        failures.removeValue(forKey: id)
        notifyChanged()
    }
    func record(_ id: String, event: TanLifecycleEvent) {
        guard installed.contains(where: { $0.id == id }) else { return }
        if event == .failed {
            failures[id, default: 0] += 1
            if failures[id, default: 0] >= 3 { setEnabled(id, false); error = "A repeatedly failing Tan was disabled." }
        }
    }
    func dismissError() { error = nil }
    private func prepareStorage() throws {
        if usesEditionScopedStorage {
            try MaomaoDataPaths.createPrivateDirectory(root)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TanError.invalid("Invalid Tan storage") }
        }
    }
    private func saveState() throws {
        try prepareStorage()
        let state = State(enabled: enabledIDs.sorted(), safeMode: safeMode, enableLog: enableLog)
        let url = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw TanError.invalid("Invalid Tan state") }
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
