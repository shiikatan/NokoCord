import Foundation
import Observation

struct TanStorageQuota: Equatable {
    static let standard = TanStorageQuota(
        maximumPackages: 64,
        maximumPackageBytes: 32 * 1024 * 1024,
        maximumTranslationArchives: 64,
        maximumTranslationBytes: 16 * 1024 * 1024
    )

    let maximumPackages: Int
    let maximumPackageBytes: Int
    let maximumTranslationArchives: Int
    let maximumTranslationBytes: Int

    init(
        maximumPackages: Int = 64,
        maximumPackageBytes: Int = 32 * 1024 * 1024,
        maximumTranslationArchives: Int = 64,
        maximumTranslationBytes: Int = 16 * 1024 * 1024
    ) {
        self.maximumPackages = maximumPackages
        self.maximumPackageBytes = maximumPackageBytes
        self.maximumTranslationArchives = maximumTranslationArchives
        self.maximumTranslationBytes = maximumTranslationBytes
    }
}

@MainActor @Observable
final class TanManager {
    private(set) var installed: [TanPackage] = []
    private(set) var enabledIDs: Set<String> = []
    private(set) var safeMode = false
    private(set) var developerMode = false
    private(set) var diagnostics: [TanDiagnostic] = []
    private(set) var trustRecords: [String: TanTrustRecord] = [:]
    private(set) var error: String?
    var reloadRequired = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let storageQuota: TanStorageQuota
    @ObservationIgnored private var trustStore: TanTrustStore?
    @ObservationIgnored private var enableLog: [String] = []
    @ObservationIgnored private var failures: [String: Int] = [:]
    private struct State: Codable {
        var version = 1
        var enabled: [String]
        var safeMode: Bool
        var developerMode: Bool
        var enableLog: [String]
    }
    init(
        root: URL? = nil,
        launchSafeMode: Bool = ProcessInfo.processInfo.arguments.contains("--safe-mode"),
        storageQuota: TanStorageQuota = .standard
    ) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NokoCord/Tans", isDirectory: true)
        self.storageQuota = storageQuota
        do {
            self.trustStore = try TanTrustStore(fileURL: self.root.appendingPathComponent("trust.json"))
        } catch {
            self.trustStore = nil
            self.safeMode = true
            self.error = "Tan trust storage could not be restored. Safe Mode is on."
        }
        do {
            try restoreInterruptedReplacements()
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
            synchronizeTrust()
        } catch {
            safeMode = true
            self.error = "Tan storage could not be restored. Safe Mode is on."
        }
        if launchSafeMode { safeMode = true }
        if trustStore == nil { enabledIDs.removeAll() }
        installed.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }
    var active: [TanPackage] {
        guard !safeMode else { return [] }
        return installed.filter { enabledIDs.contains($0.id) && trustRecords[$0.id]?.matches($0) == true }
    }
    var availableOriginals: [TanPackage] { TanPackage.originals.filter { original in !installed.contains { $0.id == original.id } } }
    func install(_ package: TanPackage) throws {
        try package.validate()
        guard let trustStore else { throw TanError.invalid("Tan trust storage is unavailable") }
        guard installed.count < storageQuota.maximumPackages || installed.contains(where: { $0.id == package.id }) else {
            throw TanError.invalid("Tan storage quota reached: \(storageQuota.maximumPackages) packages maximum")
        }
        // An import never silently replaces installed code or inherits its grants.
        guard !installed.contains(where: { $0.id == package.id }) else { throw TanError.invalid("This Tan is already installed") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(package)
        try prepareStorage()
        let url = root.appendingPathComponent(package.id + ".tan.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw TanError.invalid("A Tan package already exists at this location") }
        try ensurePackageQuota(adding: data.count, replacing: [])
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let record = try trustStore.record(package)
            trustRecords[package.id] = record
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
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
    /// Installs a bundled Noko-Tan when it is absent, then enables it. Bundled
    /// originals are first-party, but enabling one stays an explicit choice.
    func enableOriginal(_ package: TanPackage) {
        guard TanPackage.originals.contains(package) else {
            error = "Only bundled Noko-Tans can be enabled this way."
            return
        }
        do {
            if !installed.contains(where: { $0.id == package.id }) { try install(package) }
            setEnabled(package.id, true)
        } catch {
            self.error = "The Tan could not be installed. Try again from the Tan Hub."
        }
    }
    func replaceFromLocalFolder(_ package: TanPackage) throws {
        guard developerMode else { throw TanError.invalid("Enable Developer Mode to reload local code") }
        try replace(package)
    }
    private func replace(_ package: TanPackage) throws {
        try package.validate()
        guard let trustStore else { throw TanError.invalid("Tan trust storage is unavailable") }
        guard let index = installed.firstIndex(where: { $0.id == package.id }) else {
            throw TanError.invalid("Enable Developer Mode and select an installed Tan")
        }
        let previousPackage = installed[index]
        guard previousPackage.contentHash != package.contentHash else { return }
        let previousEnabled = enabledIDs
        let packageURL = root.appendingPathComponent(package.id + ".tan.json")
        let recoveryURL = root.appendingPathComponent(package.id + ".previous.tan.json")

        try trustStore.stageReplacement(package, previous: previousPackage)
        do {
            enabledIDs.remove(package.id)
            try saveState()
            onChange?()

            try writePackage(previousPackage, to: recoveryURL)
            try writePackage(package, to: packageURL)
            installed[index] = package
            trustRecords[package.id] = try trustStore.commitReplacement(package, previous: previousPackage)
            onChange?()
        } catch {
            installed[index] = previousPackage
            enabledIDs = previousEnabled
            try? writePackage(previousPackage, to: packageURL)
            _ = try? trustStore.restorePrevious(package.id)
            try? saveState()
            trustRecords[package.id] = trustStore.record(for: package.id)
            onChange?()
            throw error
        }
    }
    func installTranslation(_ result: TanTranslationResult, source: [String: String]) throws {
        let package = try result.package()
        guard !installed.contains(where: { $0.id == package.id }), source.count <= 128,
              source.values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw TanError.invalid("Invalid translation archive") }
        struct Archive: Encodable { let report: TanTranslationReport; let files: [String: String] }
        let data = try JSONEncoder().encode(Archive(report: result.report, files: source))
        guard data.count <= storageQuota.maximumTranslationBytes else {
            throw TanError.invalid("Translation archive quota reached: \(storageQuota.maximumTranslationBytes / (1024 * 1024)) MiB maximum")
        }
        try prepareStorage()
        try ensureTranslationQuota(adding: data.count)
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
        guard let package = installed.first(where: { $0.id == id }) else { return }
        let previous = enabledIDs
        if enabled {
            guard let trustStore else {
                error = "Tan trust storage is unavailable."
                return
            }
            if trustRecords[id]?.health == .quarantined {
                error = "This Tan is quarantined. Recover it before enabling it again."
                return
            }
            do {
                trustRecords[id] = try trustStore.approve(package)
                enabledIDs.insert(id)
                enableLog.append(id); enableLog = Array(enableLog.suffix(64)); failures[id] = 0
            } catch {
                self.error = "The Tan could not be approved."
                return
            }
        } else {
            enabledIDs.remove(id)
            do {
                guard let trustStore else { throw TanError.invalid("Tan trust storage is unavailable") }
                trustRecords[id] = try trustStore.setEnabled(package, false)
            } catch {
                enabledIDs = previous
                self.error = "The Tan selection could not be saved."
                return
            }
        }
        do { try saveState(); onChange?() }
        catch {
            enabledIDs = previous
            self.error = "The Tan selection could not be saved."
        }
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
        let packageRecovery = root.appendingPathComponent(id + ".previous.tan.json")
        if FileManager.default.fileExists(atPath: packageRecovery.path) { try FileManager.default.removeItem(at: packageRecovery) }
        installed.removeAll { $0.id == id }
        trustRecords.removeValue(forKey: id)
        onChange?()
    }
    func record(
        _ id: String,
        event: TanDiagnostic.Event,
        category: TanFailureCategory? = nil,
        at date: Date = Date()
    ) {
        guard let package = installed.first(where: { $0.id == id }) else { return }
        diagnostics.append(TanDiagnostic(tanID: id, event: event))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
        if event == .failed {
            recordFailure(package, category: category ?? .runtime, at: date)
        } else if event == .rejected {
            recordFailure(package, category: category ?? .rejected, at: date)
        }
    }

    /// Records a native/helper failure using an allowlisted category only.
    /// The originating error and callback payload are intentionally discarded.
    func recordHelperFailure(_ id: String, category: TanFailureCategory, at date: Date = Date()) {
        guard let package = installed.first(where: { $0.id == id }) else { return }
        recordFailure(package, category: category, at: date)
    }

    private func recordFailure(_ package: TanPackage, category: TanFailureCategory, at date: Date) {
        do {
            guard let trustStore else { throw TanError.invalid("Tan trust storage is unavailable") }
            let record = try trustStore.recordFailure(package, category: category, at: date)
            trustRecords[package.id] = record
            failures[package.id] = record.failureCount
            enabledIDs.remove(package.id)
            try? saveState()
            if record.health == .quarantined {
                error = "A repeatedly failing Tan was quarantined and disabled."
            }
            onChange?()
        } catch {
            self.error = "The Tan failure could not be recorded safely."
        }
    }

    /// Returns whether a private previous package snapshot is available for an
    /// explicit user-approved restore.
    func canRestorePrevious(_ id: String) -> Bool {
        guard let current = installed.first(where: { $0.id == id }) else { return false }
        let snapshotURL = root.appendingPathComponent(id + ".previous.tan.json")
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              let previous = try? loadPackage(at: snapshotURL) else { return false }
        return previous.id == current.id && previous.contentHash != current.contentHash
    }

    /// Restores the retained previous package atomically, leaves it disabled,
    /// and requires a fresh explicit approval before it can run.
    func restorePreviousVersion(_ id: String) {
        guard let trustStore,
              let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let packageURL = root.appendingPathComponent(id + ".tan.json")
        let snapshotURL = root.appendingPathComponent(id + ".previous.tan.json")
        guard index >= 0, index < installed.count else {
            error = "No recoverable previous version is available for this Tan."
            return
        }
        let current = installed[index]
        guard let previous = try? loadPackage(at: snapshotURL),
              previous.id == id,
              previous.contentHash != current.contentHash else {
            error = "No recoverable previous version is available for this Tan."
            return
        }
        let previousEnabled = enabledIDs
        do {
            enabledIDs.remove(id)
            try saveState()
            onChange?()
            try writePackage(previous, to: packageURL)
            installed[index] = previous
            trustRecords[id] = try trustStore.restoreSnapshot(previous)
            reloadRequired = true
            try saveState()
            error = nil
            onChange?()
        } catch {
            installed[index] = current
            enabledIDs = previousEnabled
            try? writePackage(current, to: packageURL)
            try? saveState()
            trustRecords[id] = trustStore.record(for: id)
            self.error = "The previous Tan version could not be restored."
            onChange?()
        }
    }

    /// A small compatibility overload keeps existing event call sites simple.
    private func recordFailure(_ package: TanPackage, reason: String?, at date: Date) {
        recordFailure(package, category: TanFailureCategory(sanitizing: reason), at: date)
    }

    /// Clears quarantine and requires a fresh approval before the Tan can run.
    func recoverQuarantined(_ id: String) {
        guard let package = installed.first(where: { $0.id == id }), let trustStore else { return }
        do {
            enabledIDs.remove(id)
            trustRecords[id] = try trustStore.recover(package)
            failures[id] = 0
            try saveState()
            error = nil
            onChange?()
        } catch {
            self.error = "The Tan could not be recovered."
        }
    }

    func trustRecord(for id: String) -> TanTrustRecord? {
        trustRecords[id]
    }
    func dismissError() { error = nil }
    func clearConsole() { diagnostics.removeAll() }

    private func restoreInterruptedReplacements() throws {
        guard let trustStore else { return }
        for (id, marker) in trustStore.pendingReplacementsSnapshot() {
            let packageURL = root.appendingPathComponent(id + ".tan.json")
            let recoveryURL = root.appendingPathComponent(id + ".previous.tan.json")
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                let previous = try loadPackage(at: recoveryURL)
                guard previous.id == id, previous.contentHash == marker.previousContentHash else {
                    throw TanError.invalid("Invalid interrupted Tan replacement")
                }
                try writePackage(previous, to: packageURL)
                _ = try trustStore.restorePrevious(id)
            } else if FileManager.default.fileExists(atPath: packageURL.path) {
                let current = try loadPackage(at: packageURL)
                guard current.contentHash == marker.previousContentHash else {
                    throw TanError.invalid("An interrupted Tan replacement has no recoverable previous version")
                }
                _ = try trustStore.restorePrevious(id)
            } else {
                throw TanError.invalid("An interrupted Tan replacement is missing its previous version")
            }
        }
    }

    private func synchronizeTrust() {
        guard let trustStore else { return }
        let persistedEnabled = enabledIDs
        for package in installed {
            do {
                trustRecords[package.id] = try trustStore.invalidateIfHashChanged(package)
            } catch {
                safeMode = true
                self.error = "Tan trust storage could not be verified. Safe Mode is on."
            }
        }
        enabledIDs = Set(persistedEnabled.filter { id in
            guard let package = installed.first(where: { $0.id == id }),
                  let record = trustRecords[id] else { return false }
            return record.matches(package)
        })
        if enabledIDs != persistedEnabled {
            try? saveState()
        }
    }

    private func loadPackage(at url: URL) throws -> TanPackage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
              try isPrivateFile(url) else {
            throw TanError.invalid("Invalid Tan package storage")
        }
        let package = try JSONDecoder().decode(TanPackage.self, from: Data(contentsOf: url))
        try package.validate()
        return package
    }

    private func writePackage(_ package: TanPackage, to url: URL) throws {
        try package.validate()
        try prepareStorage()
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw TanError.invalid("Invalid Tan package storage")
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values?.isSymbolicLink == true || (FileManager.default.fileExists(atPath: url.path) && values?.isRegularFile != true) {
            throw TanError.invalid("Invalid Tan package storage")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(package)
        try ensurePackageQuota(adding: data.count, replacing: [url.lastPathComponent])
        let temporary = root.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func prepareStorage() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true, try isPrivateFile(root) else {
            throw TanError.invalid("Invalid Tan storage")
        }
    }

    private func ensurePackageQuota(adding bytes: Int, replacing names: Set<String>) throws {
        guard bytes >= 0 else { throw TanError.invalid("Invalid Tan package size") }
        let files = try storedFiles(withSuffix: ".tan.json", maximumBytes: 2 * 1024 * 1024)
        var current = 0
        for file in files where !names.contains(file.lastPathComponent) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            current += values.fileSize ?? 0
        }
        guard current + bytes <= storageQuota.maximumPackageBytes else {
            throw TanError.invalid("Tan package storage quota reached: \(storageQuota.maximumPackageBytes / (1024 * 1024)) MiB maximum")
        }
    }

    private func ensureTranslationQuota(adding bytes: Int) throws {
        let files = try storedFiles(withSuffix: ".source.json", maximumBytes: storageQuota.maximumTranslationBytes)
        var current = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            current += values.fileSize ?? 0
        }
        guard files.count < storageQuota.maximumTranslationArchives,
              current + bytes <= storageQuota.maximumTranslationBytes else {
            throw TanError.invalid("Translation archive storage quota reached")
        }
    }

    private func storedFiles(withSuffix suffix: String, maximumBytes: Int) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        return try urls.filter { $0.lastPathComponent.hasSuffix(suffix) }.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // Do not follow symlinks while accounting for a quota.
            if values.isSymbolicLink == true { return nil }
            guard values.isRegularFile == true,
                  (values.fileSize ?? Int.max) <= maximumBytes,
                  try isPrivateFile(url) else {
                throw TanError.invalid("Invalid or non-private Tan storage file")
            }
            return url
        }
    }

    private func isPrivateFile(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o077 == 0
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
