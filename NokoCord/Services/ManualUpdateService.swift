import CryptoKit
import Foundation
import Darwin

enum ManualUpdateProgress: Equatable, Sendable {
    case inspecting
    case copyingArchive
    case validatingArchive
    case extracting
    case validatingApplication
    case ready(ManualUpdateCandidate)
    case staging
    case launchingHelper
    case applying
    case waitingForRelaunch
    case failed(String)
}

struct ManualUpdateApplyResult: Equatable, Sendable {
    let launchedApplicationURL: URL
    let operation: ManualUpdateOperation
    let transactionNonce: String
    let journalURL: URL
    let helperProcessIdentifier: Int32
}

/// Read-only inspection plus an explicit apply handoff. The selected ZIP is
/// privately copied while any security-scoped access is active; preview and
/// apply both refer to that copy and its digest.
actor ManualUpdateService {
    private static let minimumSupportedVersion = try! ManualUpdateVersion("1.3.0")

    private struct StoredCandidate: Sendable {
        let candidate: ManualUpdateCandidate
        let archiveCopyURL: URL
    }

    let paths: MaomaoDataPaths
    private let currentAppURL: URL
    private let validator: any ManualUpdateAppValidating
    private let currentArchitecture: String
    private var candidates: [UUID: StoredCandidate] = [:]
    private var progressObservers: [UUID: AsyncStream<ManualUpdateProgress>.Continuation] = [:]

    init(
        currentAppURL: URL = Bundle.main.bundleURL,
        paths: MaomaoDataPaths = MaomaoDataPaths(),
        validator: any ManualUpdateAppValidating = SystemManualUpdateAppValidator(),
        currentArchitecture: String = ManualUpdateService.currentProcessArchitecture
    ) {
        self.currentAppURL = URL(fileURLWithPath: currentAppURL.path, isDirectory: true)
        self.paths = paths
        self.validator = validator
        self.currentArchitecture = currentArchitecture
    }

    func progressUpdates() -> AsyncStream<ManualUpdateProgress> {
        let observerID = UUID()
        return AsyncStream { continuation in
            progressObservers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeProgressObserver(observerID) }
            }
        }
    }

    /// Read-only preview used by the Updates screen. This is separate from ZIP
    /// candidate inspection and is available after M1.3.0 whenever no scoped
    /// Tan storage or prior-import marker exists.
    func legacyTanImportAvailability() throws -> ManualUpdateTanImportAvailability {
        let metadata = try ManualUpdateApplicationMetadata.read(from: currentAppURL)
        guard metadata.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              metadata.editionID == MaomaoDataPaths.editionID else { throw ManualUpdateError.unsupportedEdition }
        guard metadata.marketingVersion >= Self.minimumSupportedVersion else {
            var unavailable = ManualUpdateLegacyTanImporter.availability(paths: paths)
            unavailable = ManualUpdateTanImportAvailability(
                eligible: false, sourcePath: unavailable.sourcePath, sourceDigest: unavailable.sourceDigest,
                packageNames: unavailable.packageNames, packageCount: unavailable.packageCount,
                translatedArchiveCount: unavailable.translatedArchiveCount, enabledCount: unavailable.enabledCount,
                safeMode: unavailable.safeMode, reason: .unsupportedBaseline
            )
            return unavailable
        }
        return ManualUpdateLegacyTanImporter.availability(paths: paths)
    }

    /// Call only after the user confirms the source preview. The digest prevents
    /// changed shared data from being imported under stale confirmation.
    func importLegacyTansOnce(
        expectedSourceDigest: String,
        refreshing tanManager: TanManager
    ) async throws -> ManualUpdateTanImportResult {
        let availability = try legacyTanImportAvailability()
        guard availability.eligible, availability.sourceDigest == expectedSourceDigest else {
            throw ManualUpdateError.staleCandidate
        }
        let imported = try ManualUpdateLegacyTanImporter.importOnce(paths: paths, expectedSourceDigest: expectedSourceDigest)
        do {
            try await tanManager.reloadFromStorage()
        } catch {
            try? ManualUpdateTransactionFiles.removeOwnedPath(paths.tanStorage)
            try? ManualUpdateTransactionFiles.removeOwnedPath(paths.noLegacyTanImportMarker)
            try? await tanManager.reloadFromStorage()
            throw error
        }
        return ManualUpdateTanImportResult(
            packageNames: imported.packageNames,
            packageCount: imported.packageCount,
            translatedArchiveCount: imported.translatedArchiveCount,
            enabledCount: imported.enabledCount,
            sourcePath: imported.sourcePath,
            sourcePreserved: true,
            tanManagerRefreshed: true
        )
    }

    /// Removes all private inspection snapshots before a new ZIP selection.
    /// The Updates UI may also call this when the user explicitly clears a
    /// candidate preview.
    func discardCandidates() throws {
        try MaomaoDataPaths.createPrivateDirectory(paths.candidateRoot)
        try MaomaoDataPaths.validateNoSymlinkComponents(at: paths.candidateRoot)
        let directories = try FileManager.default.contentsOfDirectory(at: paths.candidateRoot, includingPropertiesForKeys: nil)
        for directory in directories {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  UUID(uuidString: directory.lastPathComponent) != nil else {
                throw ManualUpdateError.unsafePath("unexpected entry in private update candidate storage")
            }
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(directory)
        }
        candidates.removeAll()
    }

    func inspect(zipURL: URL) async throws -> ManualUpdateCandidate {
        emit(.inspecting)
        let accessStarted = zipURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { zipURL.stopAccessingSecurityScopedResource() } }
        let candidateID = UUID()
        let candidateDirectory = paths.candidateRoot.appendingPathComponent(candidateID.uuidString, isDirectory: true)
        do {
            try discardCandidates()
            try MaomaoDataPaths.createPrivateDirectory(candidateDirectory)
            let privateArchive = candidateDirectory.appendingPathComponent("selected-update.zip")
            emit(.copyingArchive)
            let archiveDigest = try ManualUpdateDigest.snapshotRegularFile(
                from: zipURL, to: privateArchive, maximumSize: ManualUpdateArchiveInspector.maximumArchiveSize
            )

            emit(.validatingArchive)
            let archive = try ManualUpdateArchiveInspector.inspect(privateArchive)
            emit(.extracting)
            let extractionRoot = candidateDirectory.appendingPathComponent("unpacked", isDirectory: true)
            let appURL = try ManualUpdateArchiveInspector.extract(privateArchive, to: extractionRoot, description: archive)

            emit(.validatingApplication)
            let installed = try ManualUpdateApplicationMetadata.read(from: currentAppURL)
            let staged = try ManualUpdateApplicationMetadata.read(from: appURL)
            guard installed.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
                  installed.editionID == MaomaoDataPaths.editionID,
                  staged.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
                  staged.editionID == MaomaoDataPaths.editionID else {
                throw ManualUpdateError.unsupportedEdition
            }
            let installedValidation = try validator.validate(appURL: currentAppURL, executableURL: installed.executableURL)
            let stagedValidation = try validator.validate(appURL: appURL, executableURL: staged.executableURL)
            _ = try validateUpdaterHelper(
                in: currentAppURL,
                expectedSignature: installedValidation.signature,
                expectedArchitectures: installedValidation.architectures
            )
            let candidateHelper = try validateUpdaterHelper(
                in: appURL,
                expectedSignature: stagedValidation.signature,
                expectedArchitectures: stagedValidation.architectures
            )
            try validateSignatureTransition(from: installedValidation.signature, to: stagedValidation.signature)
            guard installedValidation.architectures.contains(currentArchitecture) else {
                throw ManualUpdateError.invalidApplication("the installed executable does not include this Mac's running architecture")
            }
            guard stagedValidation.architectures.contains(currentArchitecture) else {
                throw ManualUpdateError.invalidApplication("the executable does not include this Mac's running architecture")
            }

            let classification = classify(installed: installed, candidate: staged)

            let treeDigest = try ManualUpdateDigest.applicationTree(at: appURL)
            let installedTreeDigest = try ManualUpdateDigest.applicationTree(at: currentAppURL)
            guard try ManualUpdateDigest.file(at: privateArchive) == archiveDigest else {
                throw ManualUpdateError.invalidArchive("private ZIP snapshot changed during inspection")
            }
            let candidate = ManualUpdateCandidate(
                id: candidateID,
                archiveSHA256: archiveDigest,
                applicationTreeSHA256: treeDigest,
                stagedApplicationURL: appURL,
                bundleIdentifier: staged.bundleIdentifier,
                editionID: staged.editionID,
                marketingVersion: staged.marketingVersion,
                build: staged.build,
                installedMarketingVersion: installed.marketingVersion,
                installedBuild: installed.build,
                installedApplicationTreeSHA256: installedTreeDigest,
                installedSignature: installedValidation.signature,
                installedArchitectures: installedValidation.architectures,
                executableName: staged.executableName,
                architectures: stagedValidation.architectures,
                signature: stagedValidation.signature,
                helperSHA256: candidateHelper.digest,
                helperArchitectures: candidateHelper.validation.architectures,
                helperSignature: candidateHelper.validation.signature,
                classification: classification
            )
            candidates[candidateID] = StoredCandidate(candidate: candidate, archiveCopyURL: privateArchive)
            emit(.ready(candidate))
            return candidate
        } catch {
            try? ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(candidateDirectory)
            let message = (error as? LocalizedError)?.errorDescription ?? "Update inspection failed."
            emit(.failed(message))
            throw error
        }
    }

    /// Rechecks the immutable candidate, private ZIP copy, extracted bundle,
    /// installed app identity, signature relationship and digest immediately
    /// before apply. The actual handoff is implemented by the signed helper.
    func revalidate(_ candidate: ManualUpdateCandidate, operation: ManualUpdateOperation) throws {
        guard let stored = candidates[candidate.id], stored.candidate == candidate,
              candidate.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              candidate.editionID == MaomaoDataPaths.editionID else { throw ManualUpdateError.staleCandidate }
        guard candidate.permits(operation) else {
            if candidate.classification == .older {
                throw ManualUpdateError.versionRejected(
                    currentVersion: candidate.installedMarketingVersion.description,
                    currentBuild: candidate.installedBuild.description,
                    candidateVersion: candidate.marketingVersion.description,
                    candidateBuild: candidate.build.description
                )
            }
            if candidate.classification == .unsupportedBaseline {
                throw ManualUpdateError.baselineUnsupported(
                    currentVersion: candidate.installedMarketingVersion.description,
                    currentBuild: candidate.installedBuild.description,
                    candidateVersion: candidate.marketingVersion.description,
                    candidateBuild: candidate.build.description
                )
            }
            throw ManualUpdateError.staleCandidate
        }
        guard try ManualUpdateDigest.file(at: stored.archiveCopyURL) == candidate.archiveSHA256,
              try ManualUpdateDigest.applicationTree(at: candidate.stagedApplicationURL) == candidate.applicationTreeSHA256,
              try ManualUpdateDigest.applicationTree(at: currentAppURL) == candidate.installedApplicationTreeSHA256 else {
            throw ManualUpdateError.staleCandidate
        }
        let installed = try ManualUpdateApplicationMetadata.read(from: currentAppURL)
        let staged = try ManualUpdateApplicationMetadata.read(from: candidate.stagedApplicationURL)
        guard installed.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              installed.editionID == MaomaoDataPaths.editionID,
              installed.marketingVersion == candidate.installedMarketingVersion,
              installed.build == candidate.installedBuild,
              staged.bundleIdentifier == candidate.bundleIdentifier,
              staged.editionID == candidate.editionID,
              staged.marketingVersion == candidate.marketingVersion,
              staged.build == candidate.build,
              staged.executableName == candidate.executableName,
              classify(installed: installed, candidate: staged) == candidate.classification else { throw ManualUpdateError.staleCandidate }
        let currentValidation = try validator.validate(appURL: currentAppURL, executableURL: installed.executableURL)
        let stagedValidation = try validator.validate(appURL: candidate.stagedApplicationURL, executableURL: staged.executableURL)
        _ = try validateUpdaterHelper(
            in: currentAppURL,
            expectedSignature: currentValidation.signature,
            expectedArchitectures: currentValidation.architectures
        )
        let stagedHelper = try validateUpdaterHelper(
            in: candidate.stagedApplicationURL,
            expectedSignature: stagedValidation.signature,
            expectedArchitectures: stagedValidation.architectures
        )
        guard currentValidation.signature == candidate.installedSignature,
              currentValidation.architectures == candidate.installedArchitectures else { throw ManualUpdateError.staleCandidate }
        try validateSignatureTransition(from: currentValidation.signature, to: stagedValidation.signature)
        guard stagedValidation.signature == candidate.signature,
              stagedValidation.architectures == candidate.architectures,
              stagedValidation.architectures.contains(currentArchitecture),
              stagedHelper.digest == candidate.helperSHA256,
              stagedHelper.validation.signature == candidate.helperSignature,
              stagedHelper.validation.architectures == candidate.helperArchitectures else { throw ManualUpdateError.staleCandidate }
    }

    /// Copies the already inspected app and signed helper to a same-volume
    /// sibling transaction directory, durably publishes a narrow manifest,
    /// then waits for the helper's nonce-bound READY response. The caller may
    /// request app termination only after this method returns.
    func apply(candidate: ManualUpdateCandidate, operation: ManualUpdateOperation) async throws -> ManualUpdateApplyResult {
        try revalidate(candidate, operation: operation)
        emit(.staging)
        let nonce = UUID().uuidString
        let transactionDirectory: URL
        do {
            transactionDirectory = try ManualUpdateTransactionFiles.createTransactionDirectory(for: currentAppURL, nonce: nonce)
        } catch {
            emit(.failed(error.localizedDescription))
            throw error
        }
        var helperProcess: Process?
        do {
            let stagedURL = transactionDirectory.appendingPathComponent("Replacement.app", isDirectory: true)
            let backupURL = transactionDirectory.appendingPathComponent("Original.app", isDirectory: true)
            let manifestURL = transactionDirectory.appendingPathComponent("transaction.json")
            let journalURL = transactionDirectory.appendingPathComponent("journal.json")
            let copiedHelper = transactionDirectory.appendingPathComponent("NokoCordUpdateHelper")
            let bundledHelper = try validateUpdaterHelper(
                in: currentAppURL,
                expectedSignature: candidate.installedSignature,
                expectedArchitectures: candidate.installedArchitectures
            )
            let bundledHelperDigest = bundledHelper.digest

            try ManualUpdateTransactionFiles.copyTreeWithDitto(from: candidate.stagedApplicationURL, to: stagedURL)
            guard try ManualUpdateDigest.applicationTree(at: stagedURL) == candidate.applicationTreeSHA256 else {
                throw ManualUpdateError.staleCandidate
            }
            let stagedMetadata = try ManualUpdateApplicationMetadata.read(from: stagedURL)
            let stagedValidation = try validator.validate(appURL: stagedURL, executableURL: stagedMetadata.executableURL)
            let stagedHelper = try validateUpdaterHelper(
                in: stagedURL,
                expectedSignature: candidate.helperSignature,
                expectedArchitectures: candidate.helperArchitectures
            )
            guard stagedMetadata.bundleIdentifier == candidate.bundleIdentifier,
                  stagedMetadata.editionID == candidate.editionID,
                  stagedMetadata.marketingVersion == candidate.marketingVersion,
                  stagedMetadata.build == candidate.build,
                  stagedMetadata.executableName == candidate.executableName,
                  stagedValidation.signature == candidate.signature,
                  stagedValidation.architectures == candidate.architectures,
                  stagedHelper.digest == candidate.helperSHA256 else { throw ManualUpdateError.staleCandidate }

            let bundledValidation = bundledHelper.validation
            guard bundledValidation.architectures.contains(currentArchitecture) else {
                throw ManualUpdateError.invalidApplication("the signed updater helper does not support this Mac's architecture")
            }
            try validateSignatureTransition(from: candidate.installedSignature, to: bundledValidation.signature)
            try ManualUpdateTransactionFiles.copyExecutable(from: bundledHelper.url, to: copiedHelper)
            let copiedValidation = try validator.validateStandaloneExecutable(copiedHelper)
            guard copiedValidation == bundledValidation,
                  try ManualUpdateDigest.file(at: copiedHelper) == bundledHelperDigest else {
                throw ManualUpdateError.invalidApplication("the updater helper changed while being copied")
            }

            let processIdentity = try ManualUpdateProcessIdentity.current()
            let installedMetadata = try ManualUpdateApplicationMetadata.read(from: currentAppURL)
            let manifest = ManualUpdateTransactionManifest(
                schemaVersion: 1,
                nonce: nonce,
                operation: operation,
                process: processIdentity,
                applicationPath: currentAppURL.path,
                installedApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: currentAppURL),
                candidateApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: stagedURL),
                transactionDirectoryPath: transactionDirectory.path,
                helperPath: copiedHelper.path,
                helperSHA256: bundledHelperDigest,
                stagedApplicationPath: stagedURL.path,
                backupApplicationPath: backupURL.path,
                journalPath: journalURL.path,
                candidateBundleIdentifier: candidate.bundleIdentifier,
                candidateEditionID: candidate.editionID,
                candidateMarketingVersion: candidate.marketingVersion.description,
                candidateBuild: candidate.build.description,
                candidateExecutableName: candidate.executableName,
                candidateTreeSHA256: candidate.applicationTreeSHA256,
                candidateHelperSHA256: candidate.helperSHA256,
                candidateHelperSignature: candidate.helperSignature.transactionValue,
                candidateHelperArchitectures: candidate.helperArchitectures.sorted(),
                candidateSignature: candidate.signature.transactionValue,
                candidateArchitectures: candidate.architectures.sorted(),
                installedMarketingVersion: candidate.installedMarketingVersion.description,
                installedBuild: candidate.installedBuild.description,
                installedExecutableName: installedMetadata.executableName,
                installedTreeSHA256: candidate.installedApplicationTreeSHA256,
                installedSignature: candidate.installedSignature.transactionValue,
                installedArchitectures: candidate.installedArchitectures.sorted(),
                scopedTanStoragePath: paths.tanStorage.path,
                legacySharedTanStoragePath: paths.legacySharedTanStorage.path,
                cachePath: paths.cacheRoot.path,
                preferencesPath: paths.preferencesPlist.path,
                savedApplicationStatePath: paths.savedApplicationState.path,
                candidateRootPath: paths.candidateRoot.path,
                noLegacyImportMarkerPath: paths.noLegacyTanImportMarker.path,
                pendingUpdateTransactionPath: paths.pendingUpdateTransaction.path,
                pendingCleanResetPath: paths.pendingCleanReset.path
            )
            try ManualUpdateTransactionFiles.writeDurably(manifest, to: manifestURL, replace: false)
            try ManualUpdateTransactionFiles.writeDurably(
                ManualUpdateJournal(nonce: nonce, state: .prepared), to: journalURL, replace: false
            )
            emit(.launchingHelper)
            let process = Process()
            process.executableURL = copiedHelper
            process.arguments = ["--transaction", manifestURL.path]
            let handshake = Pipe()
            process.standardOutput = handshake
            process.standardError = FileHandle.nullDevice
            try process.run()
            helperProcess = process
            try await ManualUpdateHelperHandshake.waitForReady(handshake, nonce: nonce)
            guard process.isRunning else { throw ManualUpdateError.unavailable("The update helper exited before accepting the transaction.") }
            emit(.waitingForRelaunch)
            return ManualUpdateApplyResult(
                launchedApplicationURL: currentAppURL,
                operation: operation,
                transactionNonce: nonce,
                journalURL: journalURL,
                helperProcessIdentifier: process.processIdentifier
            )
        } catch {
            if let helperProcess, helperProcess.isRunning {
                helperProcess.terminate()
                helperProcess.waitUntilExit()
            }
            try? ManualUpdateTransactionFiles.removeOwnedPath(transactionDirectory)
            emit(.failed(error.localizedDescription))
            throw error
        }
    }

    private func validateSignatureTransition(from current: ManualUpdateSignature, to candidate: ManualUpdateSignature) throws {
        switch (current, candidate) {
        case (.developerTeam(let currentTeam), .developerTeam(let candidateTeam)) where currentTeam == candidateTeam:
            return
        case (.adHoc, .adHoc):
            return
        default:
            throw ManualUpdateError.invalidApplication("the candidate signature does not match the installed app's signing identity")
        }
    }

    private func validateUpdaterHelper(
        in appURL: URL,
        expectedSignature: ManualUpdateSignature,
        expectedArchitectures: Set<String>
    ) throws -> (url: URL, digest: String, validation: ManualUpdateAppValidation) {
        let helperURL = try ManualUpdateApplicationMetadata.updaterHelperURL(in: appURL)
        let validation = try validator.validateStandaloneExecutable(helperURL)
        guard validation.signature == expectedSignature,
              validation.architectures == expectedArchitectures,
              validation.architectures.contains(currentArchitecture) else {
            throw ManualUpdateError.invalidApplication("the bundled updater helper signature or architecture does not match its app")
        }
        return (helperURL, try ManualUpdateDigest.file(at: helperURL), validation)
    }

    private func classify(installed: ManualUpdateApplicationMetadata, candidate: ManualUpdateApplicationMetadata) -> ManualUpdateClassification {
        if installed.marketingVersion < Self.minimumSupportedVersion { return .unsupportedBaseline }
        if installed.marketingVersion < candidate.marketingVersion { return .newerMarketingVersion }
        if installed.marketingVersion == candidate.marketingVersion && installed.build < candidate.build { return .newerBuild }
        if installed.marketingVersion == candidate.marketingVersion && installed.build == candidate.build { return .sameVersionCleanReinstall }
        return .older
    }

    private func emit(_ update: ManualUpdateProgress) {
        progressObservers.values.forEach { $0.yield(update) }
    }

    private func removeProgressObserver(_ id: UUID) { progressObservers.removeValue(forKey: id) }

    static var currentProcessArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private extension ManualUpdateSignature {
    var transactionValue: String {
        switch self {
        case .developerTeam(let team): "team:\(team)"
        case .adHoc: "ad-hoc"
        }
    }
}

private enum ManualUpdateHelperHandshake {
    static func waitForReady(_ pipe: Pipe, nonce: String) async throws {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let line = try await Task.detached(priority: .userInitiated) { () throws -> String in
            var bytes = [UInt8]()
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, bytes.count <= 256 {
                var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&readiness, 1, 250)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ManualUpdateError.unavailable("Could not receive updater-helper readiness.")
                }
                if ready == 0 { continue }
                var buffer = [UInt8](repeating: 0, count: 128)
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { throw ManualUpdateError.unavailable("The updater helper did not complete its readiness handshake.") }
                bytes.append(contentsOf: buffer.prefix(count))
                if let newline = bytes.firstIndex(of: 10) {
                    return String(decoding: bytes[..<newline], as: UTF8.self)
                }
            }
            throw ManualUpdateError.unavailable("The updater helper did not become ready in time.")
        }.value
        guard line == "READY \(nonce)" else { throw ManualUpdateError.unavailable("The updater helper rejected this transaction.") }
    }
}
