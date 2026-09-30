import Foundation
import WebKit
import Darwin

enum ManualUpdateStartupPolicy {
    static func needsExclusiveRecoveryLock(state: ManualUpdateJournalState) -> Bool {
        [.swapInProgress, .backupMoved, .replacementInstalled, .cleanFilesCleared, .resetIncomplete].contains(state)
    }

    static func mayResumeCandidate(
        state: ManualUpdateJournalState,
        operation: ManualUpdateOperation,
        recoveryLockHeld: Bool = false
    ) -> Bool {
        switch operation {
        case .update:
            if [.launchRequested, .appReady].contains(state) { return true }
            return recoveryLockHeld && [.swapInProgress, .backupMoved, .replacementInstalled].contains(state)
        case .cleanReinstall:
            if [.launchRequested, .webKitResetComplete, .appReady].contains(state) { return true }
            return recoveryLockHeld && needsExclusiveRecoveryLock(state: state)
        }
    }

    static func mayCompleteCandidate(
        state: ManualUpdateJournalState,
        operation: ManualUpdateOperation,
        recoveryLockHeld: Bool
    ) -> Bool {
        if state == .appReady { return true }
        if operation == .cleanReinstall { return state == .webKitResetComplete }
        if state == .launchRequested { return true }
        return recoveryLockHeld && [.swapInProgress, .backupMoved, .replacementInstalled].contains(state)
    }

    static func candidateIsInstalled(
        identity: ManualUpdateDirectoryIdentity,
        manifest: ManualUpdateTransactionManifest
    ) -> Bool {
        identity == manifest.candidateApplicationIdentity
    }

    static func installedAppIsLive(
        identity: ManualUpdateDirectoryIdentity,
        manifest: ManualUpdateTransactionManifest
    ) -> Bool {
        identity == manifest.installedApplicationIdentity
    }
}

@MainActor
protocol ManualUpdateWebDataResetting {
    func clearWebsiteData() async throws
}

@MainActor
struct WKWebsiteDataManualResetter: ManualUpdateWebDataResetting {
    func clearWebsiteData() async throws {
        let store = WKWebsiteDataStore.default()
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}

/// Runs before NokoCord creates TanManager, WebKit, ActivityRuntime, or views
/// that use AppStorage. It validates the live replacement and replays an
/// interrupted Clean Reinstall before allowing ordinary launch state to load.
@MainActor
enum ManualUpdateStartupRecovery {
    static func currentPaths() throws -> MaomaoDataPaths {
        try ManualUpdateTransactionWorker.dataPathsForCurrentUser()
    }

    static func prepare(
        runningAppURL: URL = Bundle.main.bundleURL,
        paths: MaomaoDataPaths? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard,
        webDataResetter: (any ManualUpdateWebDataResetting)? = nil
    ) async throws -> ManualUpdateStartupReceipt? {
        let paths = try paths ?? currentPaths()
        let webDataResetter = webDataResetter ?? WKWebsiteDataManualResetter()
        var recoveryLockDescriptor: Int32?
        var recoveryLockTransferred = false
        var startupLockDescriptor: Int32?
        var startupLockTransferred = false
        defer {
            if !recoveryLockTransferred, let recoveryLockDescriptor {
                _ = flock(recoveryLockDescriptor, LOCK_UN)
                close(recoveryLockDescriptor)
            }
            if !startupLockTransferred, let startupLockDescriptor {
                _ = flock(startupLockDescriptor, LOCK_UN)
                close(startupLockDescriptor)
            }
        }
        let updateMarker = try readOptional(ManualUpdatePendingTransaction.self, at: paths.pendingUpdateTransaction, limit: 16 * 1024)
        let resetMarker = try readOptional(ManualUpdatePendingReset.self, at: paths.pendingCleanReset, limit: 16 * 1024)
        guard updateMarker != nil || resetMarker != nil else {
            try validateNoOrphanedLaunchArguments(arguments)
            return nil
        }

        let pendingManifestPath = updateMarker?.manifestPath ?? resetMarker!.manifestPath
        let pendingJournalPath = updateMarker?.journalPath ?? resetMarker!.journalPath
        let nonce = updateMarker?.nonce ?? resetMarker!.nonce
        guard resetMarker == nil || (resetMarker?.nonce == nonce
                                     && resetMarker?.manifestPath == pendingManifestPath
                                     && resetMarker?.journalPath == pendingJournalPath) else {
            throw ManualUpdateError.unsafePath("clean-reset marker does not match the update transaction")
        }
        try validateLaunchArguments(arguments, manifestPath: pendingManifestPath, journalPath: pendingJournalPath, nonce: nonce)

        let manifestURL = URL(fileURLWithPath: pendingManifestPath)
        let manifest = try ManualUpdateTransactionFiles.readManifest(at: manifestURL)
        guard manifest.nonce == nonce,
              manifest.journalPath == pendingJournalPath,
              (resetMarker == nil || manifest.operation == .cleanReinstall) else {
            throw ManualUpdateError.unsafePath("pending marker does not match the signed application transaction")
        }
        try ManualUpdateTransactionWorker.validateManifestForAppStartup(manifest, manifestURL: manifestURL)
        let journalURL = URL(fileURLWithPath: manifest.journalPath)
        let journal = try ManualUpdateTransactionWorker.readJournal(journalURL)
        guard journal.nonce == nonce else { throw ManualUpdateError.unsafePath("update journal belongs to another transaction") }

        let currentAppURL = URL(fileURLWithPath: runningAppURL.path, isDirectory: true)
        guard currentAppURL.path == manifest.applicationPath else {
            throw ManualUpdateError.unsafePath("the running app is not at the install path recorded by the updater")
        }
        try MaomaoDataPaths.validateNoSymlinkComponents(at: currentAppURL)
        let currentIdentity = try ManualUpdateDirectoryIdentity.read(at: currentAppURL)
        if ManualUpdateStartupPolicy.candidateIsInstalled(identity: currentIdentity, manifest: manifest) {
            if ManualUpdateStartupPolicy.needsExclusiveRecoveryLock(state: journal.state) {
                guard let lock = try ManualUpdateTransactionWorker.acquireStartupRecoveryLock(manifest) else {
                    throw ManualUpdateError.unavailable("The updater helper is still completing its handoff. Wait for it to finish, then reopen NokoCord.")
                }
                recoveryLockDescriptor = lock
            }
            guard ManualUpdateStartupPolicy.mayResumeCandidate(
                state: journal.state,
                operation: manifest.operation,
                recoveryLockHeld: recoveryLockDescriptor != nil
            ) else {
                throw ManualUpdateError.unavailable("The update journal is not at a safe candidate-startup point. Recovery files were retained.")
            }
            if journal.state != .appReady {
                guard let lock = try ManualUpdateTransactionWorker.acquireStartupExclusionLock(manifest) else {
                    throw ManualUpdateError.unavailable("Another NokoCord launch is already completing this update. Close this window and use the other one.")
                }
                startupLockDescriptor = lock
            }
            try ManualUpdateTransactionWorker.validateCandidate(at: currentAppURL, manifest: manifest)
            if journal.state == .appReady {
                // A crash after readiness can leave markers and the old backup.
                // The completed journal suppresses a second data wipe.
                try? ManualUpdateTransactionWorker.finishStartupRecoveryIfHelperIsGone(manifest)
                return nil
            }

            let cleanResetCompleted = manifest.operation == .cleanReinstall
            if cleanResetCompleted {
                try ManualUpdateTransactionWorker.resumeCleanResetFiles(manifest)
                try clearMaomaoPreferences(using: defaults)
                try await webDataResetter.clearWebsiteData()
                try ManualUpdateTransactionWorker.writeJournal(manifest, .webKitResetComplete)
            }
            let receipt = ManualUpdateStartupReceipt(
                manifest: manifest,
                manifestURL: manifestURL,
                cleanResetCompleted: cleanResetCompleted,
                recoveryLockDescriptor: recoveryLockDescriptor,
                startupLockDescriptor: startupLockDescriptor
            )
            recoveryLockTransferred = recoveryLockDescriptor != nil
            startupLockTransferred = startupLockDescriptor != nil
            return receipt
        }

        if ManualUpdateStartupPolicy.installedAppIsLive(identity: currentIdentity, manifest: manifest) {
            guard try ManualUpdateDigest.applicationTree(at: currentAppURL) == manifest.installedTreeSHA256 else {
                throw ManualUpdateError.staleCandidate
            }
            let resetBoundaryCrossed = resetMarker != nil || [
                ManualUpdateJournalState.resetIncomplete,
                .cleanFilesCleared,
                .launchRequested,
                .webKitResetComplete,
                .appReady
            ].contains(journal.state)
            guard !resetBoundaryCrossed else {
                throw ManualUpdateError.unavailable("Clean Reinstall reached its reset boundary, but the original app is at the install path. Transaction files were retained for recovery.")
            }
            try ManualUpdateTransactionWorker.validateInstalled(at: currentAppURL, manifest: manifest)
            guard let lock = try ManualUpdateTransactionWorker.acquireStartupRecoveryLock(manifest) else {
                throw ManualUpdateError.unavailable("An update helper is waiting for NokoCord to close. Quit this window so it can continue.")
            }
            defer { _ = flock(lock, LOCK_UN); close(lock) }
            try ManualUpdateTransactionWorker.writeJournal(manifest, .failed, message: "The original app relaunched before the replacement was committed.")
            try ManualUpdateTransactionWorker.removePendingMarkers(manifest)
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(
                URL(fileURLWithPath: manifest.transactionDirectoryPath, isDirectory: true)
            )
            return nil
        }

        throw ManualUpdateError.unavailable("Neither the expected Maomao app nor its staged replacement matches this transaction. Recovery files were retained.")
    }

    /// Call only after app models have been constructed from the post-reset
    /// state. This durable nonce-bound journal entry releases the helper to
    /// remove its backup and transaction files.
    static func complete(_ receipt: ManualUpdateStartupReceipt) throws {
        let manifest = receipt.manifest
        var recoveryLockReleased = false
        var startupLockReleased = false
        defer {
            if let lock = receipt.recoveryLockDescriptor, !recoveryLockReleased {
                _ = flock(lock, LOCK_UN)
                close(lock)
            }
            if let lock = receipt.startupLockDescriptor, !startupLockReleased {
                _ = flock(lock, LOCK_UN)
                close(lock)
            }
        }
        try ManualUpdateTransactionWorker.validateManifestForAppStartup(manifest, manifestURL: receipt.manifestURL)
        let appURL = URL(fileURLWithPath: manifest.applicationPath, isDirectory: true)
        try ManualUpdateTransactionWorker.validateCandidate(at: appURL, manifest: manifest)
        let journal = try ManualUpdateTransactionWorker.readJournal(URL(fileURLWithPath: manifest.journalPath))
        guard journal.nonce == manifest.nonce,
              ManualUpdateStartupPolicy.mayCompleteCandidate(
                state: journal.state,
                operation: manifest.operation,
                recoveryLockHeld: receipt.recoveryLockDescriptor != nil
              ) else {
            throw ManualUpdateError.unavailable("The update journal changed to a failed or rollback state before NokoCord became ready.")
        }
        if journal.state != .appReady {
            if manifest.operation == .cleanReinstall {
                guard receipt.cleanResetCompleted, journal.state == .webKitResetComplete else {
                    throw ManualUpdateError.unavailable("Clean Reinstall has not completed the WebKit reset.")
                }
            }
            try ManualUpdateTransactionWorker.writeJournal(manifest, .appReady)
        }
        if let lock = receipt.startupLockDescriptor {
            _ = flock(lock, LOCK_UN)
            close(lock)
            startupLockReleased = true
        }
        if let lock = receipt.recoveryLockDescriptor {
            _ = flock(lock, LOCK_UN)
            close(lock)
            recoveryLockReleased = true
        }
        // If the helper exited during launch, finish its post-readiness cleanup
        // here while preserving the same lock and commit-point rules.
        try? ManualUpdateTransactionWorker.finishStartupRecoveryIfHelperIsGone(manifest)
    }

    static func clearMaomaoPreferences(using defaults: UserDefaults) throws {
        defaults.removePersistentDomain(forName: MaomaoDataPaths.bundleIdentifier)
        guard defaults.synchronize() else {
            throw ManualUpdateError.unavailable("Maomao preferences could not be reset safely. Retry Clean Reinstall.")
        }
    }

    private static func readOptional<T: Decodable>(_ type: T.Type, at url: URL, limit: Int) throws -> T? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw ManualUpdateError.unsafePath("could not inspect a pending update marker")
        }
        let descriptor = try ManualUpdateTransactionFiles.openRegularFileNoFollow(url.path)
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              info.st_size <= limit else {
            throw ManualUpdateError.unsafePath("pending update marker is not a bounded regular file")
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("could not read pending update marker")
            }
            guard count > 0 else { throw ManualUpdateError.unsafePath("pending update marker changed while being read") }
            offset += count
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func validateNoOrphanedLaunchArguments(_ arguments: [String]) throws {
        if arguments.contains("--noko-update-manifest")
            || arguments.contains("--noko-update-journal")
            || arguments.contains("--noko-update-nonce") {
            throw ManualUpdateError.unavailable("Updater launch arguments are present, but the transaction marker is missing. Recovery files were retained.")
        }
    }

    private static func validateLaunchArguments(
        _ arguments: [String], manifestPath: String, journalPath: String, nonce: String
    ) throws {
        let manifestArg = argumentValue("--noko-update-manifest", in: arguments)
        let journalArg = argumentValue("--noko-update-journal", in: arguments)
        let nonceArg = argumentValue("--noko-update-nonce", in: arguments)
        if manifestArg == nil && journalArg == nil && nonceArg == nil { return }
        guard manifestArg == manifestPath, journalArg == journalPath, nonceArg == nonce else {
            throw ManualUpdateError.unsafePath("updater launch arguments do not match the pending transaction")
        }
    }

    private static func argumentValue(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
