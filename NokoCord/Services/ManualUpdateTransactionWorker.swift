import Darwin
import Foundation

/// Transaction half that runs from the updater helper copied outside the app
/// before the old process exits. Every app/data path comes from the narrow
/// nonce-bound manifest and is checked against the Maomao path resolver.
enum ManualUpdateTransactionWorker {
    static func run(manifestURL: URL, emitReady: (String) -> Void) throws {
        let manifest = try ManualUpdateTransactionFiles.readManifest(at: manifestURL)
        try validateManifest(manifest, manifestURL: manifestURL, requireRunningHelper: true)
        let lockFD = try acquireTransactionLock(manifest)
        var transactionLockReleased = false
        defer {
            if !transactionLockReleased {
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        let journalURL = URL(fileURLWithPath: manifest.journalPath)
        try writeJournal(manifest, .helperReady)
        emitReady(manifest.nonce)

        do {
            try writeJournal(manifest, .waitingForOldProcess)
            try waitForOriginalProcess(manifest)
            try writeJournal(manifest, .oldProcessExited)
            try validateInstalledBaseline(manifest)
            try validateStagedCandidate(manifest)
            try writePendingTransaction(manifest)
            try writeJournal(manifest, .swapInProgress)
            try ManualUpdateTransactionFiles.swapSameVolumeDirectories(
                URL(fileURLWithPath: manifest.applicationPath),
                URL(fileURLWithPath: manifest.stagedApplicationPath)
            )
            try writeJournal(manifest, .backupMoved)

            // After the atomic exchange the candidate is live and the original
            // is at the former staging path. Revalidate both before moving the
            // original into its durable backup name.
            try validateCandidate(at: URL(fileURLWithPath: manifest.applicationPath), manifest: manifest)
            try validateInstalled(at: URL(fileURLWithPath: manifest.stagedApplicationPath), manifest: manifest)
            try ManualUpdateTransactionFiles.renameSameVolume(
                from: URL(fileURLWithPath: manifest.stagedApplicationPath),
                to: URL(fileURLWithPath: manifest.backupApplicationPath), expectedSource: .directory
            )
            try writeJournal(manifest, .replacementInstalled)

            _ = try applyCleanResetIfNeeded(manifest)

            try writeJournal(manifest, .launchRequested)
            try launchReplacement(manifest)
            try waitForReadiness(manifest, timeout: 90)
        } catch {
            let journal = try? readJournal(journalURL)
            if journal?.nonce == manifest.nonce, journal?.state == .appReady {
                try finalizeCommittedTransaction(manifest)
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
                transactionLockReleased = true
                return
            }
            try? persistFailureResult(manifest, error: error, status: .recoveryPending, recovery: "The updater failed; recovery is being checked.")
            let resetBoundaryCrossed = manifest.operation == .cleanReinstall
                && (journal?.state == .resetIncomplete || journal?.state == .cleanFilesCleared || journal?.state == .launchRequested || journal?.state == .webKitResetComplete)
            if resetBoundaryCrossed {
                try? writeJournal(manifest, .resetIncomplete, message: error.localizedDescription)
                try? persistFailureResult(manifest, error: error, status: .recoveryPending, recovery: "Clean Reinstall reached its reset boundary; recovery data was retained.")
                // Clean data crossed its durable point of no return. Keep the
                // new app and backup for retry; never restore build 3.
                throw error
            }
            let swapped = try transactionHasSwapped(manifest)
            var startupLockDescriptor: Int32?
            var startupLockReleased = false
            defer {
                if let startupLockDescriptor, !startupLockReleased {
                    _ = flock(startupLockDescriptor, LOCK_UN)
                    close(startupLockDescriptor)
                }
            }
            if swapped {
                guard let lock = try acquireStartupExclusionLock(manifest) else {
                    let latest = try? readJournal(journalURL)
                    if latest?.nonce == manifest.nonce, latest?.state == .appReady {
                        try finalizeCommittedTransaction(manifest)
                        _ = flock(lockFD, LOCK_UN)
                        close(lockFD)
                        transactionLockReleased = true
                        return
                    }
                    try? persistFailureResult(manifest, error: error, status: .recoveryPending, recovery: "Another NokoCord launch is completing recovery; transaction files were retained.")
                    throw ManualUpdateError.unavailable("NokoCord is still starting the replacement. The candidate and recovery files were retained; reopen NokoCord after startup finishes.")
                }
                startupLockDescriptor = lock
                let latest = try readJournal(journalURL)
                guard latest.nonce == manifest.nonce else { throw ManualUpdateError.staleCandidate }
                if latest.state == .appReady {
                    _ = flock(lock, LOCK_UN)
                    close(lock)
                    startupLockReleased = true
                    try finalizeCommittedTransaction(manifest)
                    _ = flock(lockFD, LOCK_UN)
                    close(lockFD)
                    transactionLockReleased = true
                    return
                }
                let latestResetBoundaryCrossed = manifest.operation == .cleanReinstall
                    && [.resetIncomplete, .cleanFilesCleared, .launchRequested, .webKitResetComplete].contains(latest.state)
                if latestResetBoundaryCrossed {
                    _ = flock(lock, LOCK_UN)
                    close(lock)
                    startupLockReleased = true
                    try? writeJournal(manifest, .resetIncomplete, message: error.localizedDescription)
                    try? persistFailureResult(manifest, error: error, status: .recoveryPending, recovery: "Clean Reinstall reached its reset boundary; recovery data was retained.")
                    throw error
                }
                try terminateCandidateProcesses(manifest)
                try rollback(manifest, reason: error.localizedDescription)
                try? persistFailureResult(manifest, error: error, status: .previousAppRestored, recovery: "The previous app was restored.")
            } else {
                try validateInstalled(at: URL(fileURLWithPath: manifest.applicationPath), manifest: manifest)
                try? writeJournal(manifest, .failed, message: error.localizedDescription)
                try? persistFailureResult(manifest, error: error, status: .previousAppStillInstalled, recovery: "The previous app remains installed.")
            }
            let markersRemoved: Bool
            do {
                try removePendingMarkers(manifest)
                markersRemoved = true
            } catch {
                markersRemoved = false
            }
            if markersRemoved {
                try? ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(
                    URL(fileURLWithPath: manifest.transactionDirectoryPath, isDirectory: true)
                )
            }
            if let startupLockDescriptor {
                _ = flock(startupLockDescriptor, LOCK_UN)
                close(startupLockDescriptor)
                startupLockReleased = true
            }
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            transactionLockReleased = true
            try launchRestoredApplication(manifest)
            throw error
        }

        // App readiness is the commit point. Backup cleanup stays outside the
        // rollback catch so a removal failure can never resurrect old data.
        try finalizeCommittedTransaction(manifest)
    }

    private static func finalizeCommittedTransaction(_ manifest: ManualUpdateTransactionManifest) throws {
        do {
            for url in [URL(fileURLWithPath: manifest.backupApplicationPath), URL(fileURLWithPath: manifest.stagedApplicationPath)] {
                var info = stat()
                if lstat(url.path, &info) == 0 {
                    try validateInstalled(at: url, manifest: manifest)
                    try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(url)
                } else if errno != ENOENT {
                    throw ManualUpdateError.unsafePath("could not inspect an original app backup after readiness")
                }
            }
            try removePendingMarkers(manifest)
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(
                URL(fileURLWithPath: manifest.transactionDirectoryPath, isDirectory: true)
            )
        } catch {
            try? persistFailureResult(
                manifest,
                error: error,
                status: .replacementReadyCleanupIncomplete,
                recovery: "The replacement app is ready, but updater cleanup failed; recovery files were retained."
            )
            throw error
        }
        try? clearFailureResult(for: manifest)
    }

    static func persistFailureResult(
        _ manifest: ManualUpdateTransactionManifest,
        error: Error,
        status: ManualUpdateHelperFailureStatus,
        recovery: String,
        pathsOverride: MaomaoDataPaths? = nil
    ) throws {
        let paths = try pathsOverride ?? dataPathsForCurrentUser()
        let resultURL = paths.helperFailureResult
        try MaomaoDataPaths.createPrivateDirectory(paths.updateRoot)
        let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .replacingOccurrences(of: manifest.transactionDirectoryPath, with: "the updater recovery folder")
            .replacingOccurrences(of: manifest.applicationPath, with: "the Maomao app folder")
        let result = ManualUpdateHelperFailureResult(
            nonce: manifest.nonce,
            operation: manifest.operation,
            status: status,
            installedVersion: manifest.installedMarketingVersion,
            installedBuild: manifest.installedBuild,
            candidateVersion: manifest.candidateMarketingVersion,
            candidateBuild: manifest.candidateBuild,
            message: String(message.prefix(1_000)),
            recovery: String(recovery.prefix(300)),
            occurredAt: Date()
        )
        try ManualUpdateTransactionFiles.writeDurably(result, to: resultURL, replace: true)
    }

    static func clearFailureResult(
        for manifest: ManualUpdateTransactionManifest,
        pathsOverride: MaomaoDataPaths? = nil
    ) throws {
        let paths = try pathsOverride ?? dataPathsForCurrentUser()
        guard let result = try readFailureResult(at: paths.helperFailureResult), result.nonce == manifest.nonce else { return }
        try ManualUpdateTransactionFiles.removeOwnedPath(paths.helperFailureResult)
    }

    static func clearPreviousFailureResult(
        for manifest: ManualUpdateTransactionManifest,
        pathsOverride: MaomaoDataPaths? = nil
    ) throws {
        let paths = try pathsOverride ?? dataPathsForCurrentUser()
        guard let result = try readFailureResult(at: paths.helperFailureResult), result.nonce != manifest.nonce else { return }
        try ManualUpdateTransactionFiles.removeOwnedPath(paths.helperFailureResult)
    }

    private static func readFailureResult(at url: URL) throws -> ManualUpdateHelperFailureResult? {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        var pathInfo = stat()
        if lstat(url.path, &pathInfo) != 0 {
            guard errno == ENOENT else { throw ManualUpdateError.unsafePath("could not inspect the saved updater result") }
            return nil
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ManualUpdateError.unsafePath("the saved updater result is not a regular file")
        }
        let descriptor = try ManualUpdateTransactionFiles.openRegularFileNoFollow(url.path)
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_size > 0, openedInfo.st_size <= 8 * 1024 else {
            throw ManualUpdateError.unsafePath("the saved updater result is not a bounded regular file")
        }
        var data = Data(count: Int(openedInfo.st_size))
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("could not read the saved updater result")
            }
            guard amount > 0 else { throw ManualUpdateError.unsafePath("the saved updater result changed while being read") }
            offset += amount
        }
        let result = try JSONDecoder().decode(ManualUpdateHelperFailureResult.self, from: data)
        guard UUID(uuidString: result.nonce) != nil else { throw ManualUpdateError.unsafePath("the saved updater result has an invalid transaction identifier") }
        return result
    }

    static func manifestURLFromArguments(_ arguments: [String]) throws -> URL {
        guard arguments.count == 3, arguments[1] == "--transaction",
              arguments[2].hasPrefix("/") else {
            throw ManualUpdateError.unavailable("Invalid updater helper arguments.")
        }
        return URL(fileURLWithPath: arguments[2])
    }

    static func validateManifestForAppStartup(_ manifest: ManualUpdateTransactionManifest, manifestURL: URL) throws {
        try validateManifest(manifest, manifestURL: manifestURL, requireRunningHelper: false)
    }

    private static func validateManifest(
        _ manifest: ManualUpdateTransactionManifest,
        manifestURL: URL,
        requireRunningHelper: Bool
    ) throws {
        guard manifest.schemaVersion == 1,
              UUID(uuidString: manifest.nonce) != nil,
              manifest.candidateBundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              manifest.candidateEditionID == MaomaoDataPaths.editionID,
              manifestURL.path == manifest.transactionDirectoryPath + "/transaction.json",
              manifest.helperPath == manifest.transactionDirectoryPath + "/NokoCordUpdateHelper",
              manifest.stagedApplicationPath == manifest.transactionDirectoryPath + "/Replacement.app",
              manifest.backupApplicationPath == manifest.transactionDirectoryPath + "/Original.app",
              manifest.journalPath == manifest.transactionDirectoryPath + "/journal.json",
              URL(fileURLWithPath: manifest.transactionDirectoryPath).deletingLastPathComponent().path == URL(fileURLWithPath: manifest.applicationPath).deletingLastPathComponent().path,
              URL(fileURLWithPath: manifest.transactionDirectoryPath).lastPathComponent == ".NokoCord-Update-\(manifest.nonce)" else {
            throw ManualUpdateError.unsafePath("transaction manifest identity or sibling paths do not match")
        }
        let paths = try dataPathsForCurrentUser()
        guard manifest.scopedTanStoragePath == paths.tanStorage.path,
              manifest.legacySharedTanStoragePath == paths.legacySharedTanStorage.path,
              manifest.cachePath == paths.cacheRoot.path,
              manifest.preferencesPath == paths.preferencesPlist.path,
              manifest.savedApplicationStatePath == paths.savedApplicationState.path,
              manifest.candidateRootPath == paths.candidateRoot.path,
              manifest.noLegacyImportMarkerPath == paths.noLegacyTanImportMarker.path,
              manifest.pendingUpdateTransactionPath == paths.pendingUpdateTransaction.path,
              manifest.pendingCleanResetPath == paths.pendingCleanReset.path else {
            throw ManualUpdateError.unsafePath("transaction requested a path outside this user's Maomao data boundary")
        }
        let candidateVersion = try ManualUpdateVersion(manifest.candidateMarketingVersion)
        let candidateBuild = try ManualUpdateBuild(manifest.candidateBuild)
        let installedVersion = try ManualUpdateVersion(manifest.installedMarketingVersion)
        let installedBuild = try ManualUpdateBuild(manifest.installedBuild)
        let minimum = try ManualUpdateVersion("1.3.0")
        guard installedVersion >= minimum else { throw ManualUpdateError.baselineUnsupported(currentVersion: installedVersion.description, currentBuild: installedBuild.description, candidateVersion: candidateVersion.description, candidateBuild: candidateBuild.description) }
        let isNewer = candidateVersion > installedVersion || (candidateVersion == installedVersion && candidateBuild > installedBuild)
        let isExact = candidateVersion == installedVersion && candidateBuild == installedBuild
        guard (manifest.operation == .update && isNewer) || (manifest.operation == .cleanReinstall && isExact) else {
            throw ManualUpdateError.staleCandidate
        }
        guard manifest.candidateExecutableName.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              manifest.installedExecutableName.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              isSHA256(manifest.candidateTreeSHA256),
              isSHA256(manifest.candidateHelperSHA256),
              isSHA256(manifest.installedTreeSHA256),
              manifest.candidateHelperSignature == manifest.candidateSignature,
              isValidSignatureString(manifest.candidateSignature),
              isValidSignatureString(manifest.installedSignature),
              manifest.installedApplicationIdentity.inode != 0,
              manifest.candidateApplicationIdentity.inode != 0,
              manifest.installedApplicationIdentity.device == manifest.candidateApplicationIdentity.device,
              manifest.installedApplicationIdentity != manifest.candidateApplicationIdentity,
              validArchitectureList(manifest.candidateArchitectures),
              validArchitectureList(manifest.candidateHelperArchitectures),
              validArchitectureList(manifest.installedArchitectures),
              Set(manifest.candidateHelperArchitectures) == Set(manifest.candidateArchitectures) else {
            throw ManualUpdateError.unsafePath("transaction application metadata is malformed")
        }
        try MaomaoDataPaths.validateNoSymlinkComponents(at: URL(fileURLWithPath: manifest.transactionDirectoryPath))
        try MaomaoDataPaths.validateNoSymlinkComponents(at: URL(fileURLWithPath: manifest.applicationPath))
        try MaomaoDataPaths.validateNoSymlinkComponents(at: URL(fileURLWithPath: manifest.stagedApplicationPath))
        let helper = URL(fileURLWithPath: manifest.helperPath)
        if requireRunningHelper {
            guard CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).path }) == helper.path else {
                throw ManualUpdateError.unsafePath("helper executable does not match transaction manifest")
            }
        }
        var helperInfo = stat()
        guard lstat(helper.path, &helperInfo) == 0, (helperInfo.st_mode & S_IFMT) == S_IFREG,
              helperInfo.st_mode & 0o111 != 0 else { throw ManualUpdateError.unsafePath("transaction helper is not a regular executable") }
        guard manifest.helperSHA256.count == 64,
              try ManualUpdateDigest.file(at: helper) == manifest.helperSHA256 else {
            throw ManualUpdateError.staleCandidate
        }
        let helperValidation = try SystemManualUpdateAppValidator().validateStandaloneExecutable(helper)
        try validateSameSignature(installed: manifest.installedSignature, candidate: signatureString(helperValidation.signature))
        guard helperValidation.architectures.contains(currentArchitecture) else {
            throw ManualUpdateError.invalidApplication("updater helper does not support this Mac's architecture")
        }
    }

    static func dataPathsForCurrentUser() throws -> MaomaoDataPaths {
        #if DEBUG
        if let home = ProcessInfo.processInfo.environment["NOKOCORD_UPDATER_TEST_HOME"], home.hasPrefix("/") {
            return MaomaoDataPaths(home: URL(fileURLWithPath: home, isDirectory: true))
        }
        #endif
        return MaomaoDataPaths()
    }

    private static func acquireTransactionLock(_ manifest: ManualUpdateTransactionManifest) throws -> Int32 {
        guard let descriptor = try acquireStartupRecoveryLock(manifest) else {
            throw ManualUpdateError.unavailable("Another helper already owns this update transaction.")
        }
        return descriptor
    }

    /// Returns nil when the helper holds the process-shared lock. Startup uses
    /// the same lock to distinguish an active handoff from an abandoned one.
    static func acquireStartupRecoveryLock(_ manifest: ManualUpdateTransactionManifest) throws -> Int32? {
        try acquireTransactionScopedLock(named: ".transaction.lock", manifest: manifest)
    }

    /// Candidate app instances serialize their startup/reset work separately
    /// from the helper lock, which the helper intentionally holds until appReady.
    static func acquireStartupExclusionLock(_ manifest: ManualUpdateTransactionManifest) throws -> Int32? {
        try acquireTransactionScopedLock(named: ".startup.lock", manifest: manifest)
    }

    private static func acquireTransactionScopedLock(named lockName: String, manifest: ManualUpdateTransactionManifest) throws -> Int32? {
        let directory = try ManualUpdateTransactionFiles.openDirectoryNoFollow(manifest.transactionDirectoryPath)
        defer { close(directory) }
        let descriptor = openat(directory, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ManualUpdateError.unsafePath("could not open updater lock") }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ManualUpdateError.unsafePath("updater lock is not a regular file")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
        let lockError = errno
        close(descriptor)
        if lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
        throw ManualUpdateError.unsafePath("could not acquire updater lock")
    }

    @discardableResult
    static func finishStartupRecoveryIfHelperIsGone(_ manifest: ManualUpdateTransactionManifest) throws -> Bool {
        guard let lock = try acquireStartupRecoveryLock(manifest) else { return false }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let journal = try readJournal(URL(fileURLWithPath: manifest.journalPath))
        guard journal.nonce == manifest.nonce, journal.state == .appReady else { return false }
        let backup = URL(fileURLWithPath: manifest.backupApplicationPath)
        var backupInfo = stat()
        if lstat(backup.path, &backupInfo) == 0 {
            try validateInstalled(at: backup, manifest: manifest)
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(backup)
        } else if errno != ENOENT {
            throw ManualUpdateError.unsafePath("could not inspect transaction backup")
        }
        let stage = URL(fileURLWithPath: manifest.stagedApplicationPath)
        var stageInfo = stat()
        if lstat(stage.path, &stageInfo) == 0 {
            try validateInstalled(at: stage, manifest: manifest)
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(stage)
        } else if errno != ENOENT {
            throw ManualUpdateError.unsafePath("could not inspect transaction staging app")
        }
        try removePendingMarkers(manifest)
        try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(URL(fileURLWithPath: manifest.transactionDirectoryPath))
        return true
    }

    private static func writePendingTransaction(_ manifest: ManualUpdateTransactionManifest) throws {
        let paths = try dataPathsForCurrentUser()
        try MaomaoDataPaths.createPrivateDirectory(paths.updateRoot)
        let pending = ManualUpdatePendingTransaction(
            nonce: manifest.nonce,
            manifestPath: URL(fileURLWithPath: manifest.transactionDirectoryPath).appendingPathComponent("transaction.json").path,
            journalPath: manifest.journalPath
        )
        try ManualUpdateTransactionFiles.writeDurably(
            pending, to: URL(fileURLWithPath: manifest.pendingUpdateTransactionPath), replace: false
        )
        try writeJournal(manifest, .pendingUpdate)
    }

    static func removePendingMarkers(_ manifest: ManualUpdateTransactionManifest) throws {
        for path in [manifest.pendingUpdateTransactionPath, manifest.pendingCleanResetPath] {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw ManualUpdateError.unsafePath("pending update marker is not a regular file") }
                try ManualUpdateTransactionFiles.removeOwnedPath(URL(fileURLWithPath: path))
            } else if errno != ENOENT {
                throw ManualUpdateError.unsafePath("could not inspect pending update marker")
            }
        }
    }

    private static func waitForOriginalProcess(_ manifest: ManualUpdateTransactionManifest) throws {
        let identity = manifest.process
        let executable = URL(fileURLWithPath: manifest.applicationPath)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(manifest.installedExecutableName)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if !identity.stillMatchesRunningProcess() {
                try waitForAppProcessToExit(executable: executable, until: deadline)
                return
            }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_pidpath(identity.pid, &path, UInt32(path.count))
            if length <= 0 {
                try waitForAppProcessToExit(executable: executable, until: deadline)
                return
            }
            let runningPath = String(cString: path)
            guard runningPath == executable.path else {
                throw ManualUpdateError.staleCandidate
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw ManualUpdateError.unavailable("NokoCord did not quit in time to apply the update.")
    }

    private static func waitForAppProcessToExit(executable: URL, until deadline: Date) throws {
        while Date() < deadline {
            let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard needed > 0 else { throw ManualUpdateError.unavailable("Could not verify that NokoCord has exited.") }
            let count = Int(needed / Int32(MemoryLayout<pid_t>.size)) + 16
            var pids = [pid_t](repeating: 0, count: count)
            let bytes = pids.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { throw ManualUpdateError.unavailable("Could not enumerate running processes before replacement.") }
            let returned = min(Int(bytes / Int32(MemoryLayout<pid_t>.size)), pids.count)
            var matchingProcessFound = false
            for pid in pids.prefix(returned) where pid > 0 && pid != getpid() {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                   String(cString: path) == executable.path {
                    matchingProcessFound = true
                    break
                }
            }
            if !matchingProcessFound { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw ManualUpdateError.unavailable("A NokoCord process is still running; replacement was postponed.")
    }

    /// A failed normal-update startup may be showing the recovery screen while
    /// the helper's readiness deadline expires. Stop that candidate process
    /// before restoring the original bundle at its executable path.
    private static func terminateCandidateProcesses(_ manifest: ManualUpdateTransactionManifest) throws {
        let executable = URL(fileURLWithPath: manifest.applicationPath)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(manifest.candidateExecutableName)
        let gracefulDeadline = Date().addingTimeInterval(5)
        while Date() < gracefulDeadline {
            let pids = try processIDs(executable: executable)
            if pids.isEmpty { return }
            for pid in pids where kill(pid, SIGTERM) != 0 && errno != ESRCH {
                throw ManualUpdateError.unavailable("The failed replacement app could not be stopped for rollback.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let remaining = try processIDs(executable: executable)
        for pid in remaining where kill(pid, SIGKILL) != 0 && errno != ESRCH {
            throw ManualUpdateError.unavailable("The failed replacement app is still running; rollback was postponed.")
        }
        let finalDeadline = Date().addingTimeInterval(5)
        while Date() < finalDeadline {
            if try processIDs(executable: executable).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ManualUpdateError.unavailable("The failed replacement app is still running; rollback was postponed.")
    }

    private static func processIDs(executable: URL) throws -> [pid_t] {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { throw ManualUpdateError.unavailable("Could not enumerate processes before rollback.") }
        let capacity = Int(required / Int32(MemoryLayout<pid_t>.size)) + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { throw ManualUpdateError.unavailable("Could not enumerate processes before rollback.") }
        let returned = min(Int(bytes / Int32(MemoryLayout<pid_t>.size)), pids.count)
        return pids.prefix(returned).filter { pid in
            guard pid > 0, pid != getpid() else { return false }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == executable.path
        }
    }

    private static func validateInstalledBaseline(_ manifest: ManualUpdateTransactionManifest) throws {
        try validateInstalled(at: URL(fileURLWithPath: manifest.applicationPath), manifest: manifest)
    }

    static func validateInstalled(
        at app: URL,
        manifest: ManualUpdateTransactionManifest,
        validator: any ManualUpdateAppValidating = SystemManualUpdateAppValidator()
    ) throws {
        let metadata = try ManualUpdateApplicationMetadata.read(from: app)
        guard metadata.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              metadata.editionID == MaomaoDataPaths.editionID,
              metadata.marketingVersion.description == manifest.installedMarketingVersion,
              metadata.build.description == manifest.installedBuild,
              metadata.executableName == manifest.installedExecutableName,
              try ManualUpdateDirectoryIdentity.read(at: app) == manifest.installedApplicationIdentity,
              try ManualUpdateDigest.applicationTree(at: app) == manifest.installedTreeSHA256 else {
            throw ManualUpdateError.staleCandidate
        }
        let validation = try validator.validate(appURL: app, executableURL: metadata.executableURL)
        guard signatureString(validation.signature) == manifest.installedSignature,
              validation.architectures.sorted() == manifest.installedArchitectures.sorted() else {
            throw ManualUpdateError.staleCandidate
        }
    }

    private static func validateStagedCandidate(_ manifest: ManualUpdateTransactionManifest) throws {
        try validateCandidate(at: URL(fileURLWithPath: manifest.stagedApplicationPath), manifest: manifest)
    }

    static func validateCandidate(
        at app: URL,
        manifest: ManualUpdateTransactionManifest,
        validator: any ManualUpdateAppValidating = SystemManualUpdateAppValidator()
    ) throws {
        let metadata = try ManualUpdateApplicationMetadata.read(from: app)
        guard metadata.bundleIdentifier == manifest.candidateBundleIdentifier,
              metadata.editionID == manifest.candidateEditionID,
              metadata.marketingVersion.description == manifest.candidateMarketingVersion,
              metadata.build.description == manifest.candidateBuild,
              metadata.executableName == manifest.candidateExecutableName,
              try ManualUpdateDirectoryIdentity.read(at: app) == manifest.candidateApplicationIdentity,
              try ManualUpdateDigest.applicationTree(at: app) == manifest.candidateTreeSHA256 else {
            throw ManualUpdateError.staleCandidate
        }
        let validation = try validator.validate(appURL: app, executableURL: metadata.executableURL)
        guard signatureString(validation.signature) == manifest.candidateSignature,
              validation.architectures.sorted() == manifest.candidateArchitectures.sorted(),
              validation.architectures.contains(currentArchitecture) else {
            throw ManualUpdateError.staleCandidate
        }
        let helperURL = try ManualUpdateApplicationMetadata.updaterHelperURL(in: app)
        guard try ManualUpdateDigest.file(at: helperURL) == manifest.candidateHelperSHA256 else {
            throw ManualUpdateError.staleCandidate
        }
        let helperValidation = try validator.validateStandaloneExecutable(helperURL)
        guard signatureString(helperValidation.signature) == manifest.candidateHelperSignature,
              helperValidation.architectures.sorted() == manifest.candidateHelperArchitectures.sorted(),
              helperValidation.architectures.contains(currentArchitecture) else {
            throw ManualUpdateError.staleCandidate
        }
        try validateSameSignature(installed: manifest.installedSignature, candidate: manifest.candidateSignature)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    @discardableResult
    static func applyCleanResetIfNeeded(
        _ manifest: ManualUpdateTransactionManifest,
        pathsOverride: MaomaoDataPaths? = nil
    ) throws -> Bool {
        guard manifest.operation == .cleanReinstall else { return false }
        try resumeCleanResetFiles(manifest, pathsOverride: pathsOverride)
        return true
    }

    static func resumeCleanResetFiles(_ manifest: ManualUpdateTransactionManifest, pathsOverride: MaomaoDataPaths? = nil) throws {
        let pendingURL = URL(fileURLWithPath: manifest.pendingCleanResetPath)
        let journalURL = URL(fileURLWithPath: manifest.journalPath)
        let paths = try pathsOverride ?? dataPathsForCurrentUser()
        guard manifest.scopedTanStoragePath == paths.tanStorage.path,
              manifest.cachePath == paths.cacheRoot.path,
              manifest.preferencesPath == paths.preferencesPlist.path,
              manifest.savedApplicationStatePath == paths.savedApplicationState.path,
              manifest.candidateRootPath == paths.candidateRoot.path,
              manifest.noLegacyImportMarkerPath == paths.noLegacyTanImportMarker.path,
              manifest.pendingCleanResetPath == paths.pendingCleanReset.path else {
            throw ManualUpdateError.unsafePath("clean-reset paths do not match Maomao's current data boundary")
        }
        try MaomaoDataPaths.createPrivateDirectory(paths.updateRoot)
        try clearPreviousFailureResult(for: manifest, pathsOverride: paths)
        let pending = ManualUpdatePendingReset(nonce: manifest.nonce, manifestPath: URL(fileURLWithPath: manifest.transactionDirectoryPath).appendingPathComponent("transaction.json").path, journalPath: manifest.journalPath)
        // This durable marker is the point of no return. Any failure after it
        // leaves the new app in place and resumes clean startup before runtime.
        try ManualUpdateTransactionFiles.writeDurably(pending, to: pendingURL, replace: true)
        try ManualUpdateTransactionFiles.writeDurably(ManualUpdateJournal(nonce: manifest.nonce, state: .resetIncomplete, message: "Clean Reinstall is in progress."), to: journalURL, replace: true)
        try writeNoImportMarker(manifest)

        let tan = URL(fileURLWithPath: manifest.scopedTanStoragePath, isDirectory: true)
        let cache = URL(fileURLWithPath: manifest.cachePath, isDirectory: true)
        let preferences = URL(fileURLWithPath: manifest.preferencesPath)
        let savedState = URL(fileURLWithPath: manifest.savedApplicationStatePath, isDirectory: true)
        try removeIfPresent(tan)
        try removeIfPresent(cache)
        try removeIfPresent(preferences)
        try removeIfPresent(savedState)
        try removeStagingIfPresent(URL(fileURLWithPath: manifest.candidateRootPath, isDirectory: true))
        try MaomaoDataPaths.createPrivateDirectory(tan)
        try writeJournal(manifest, .cleanFilesCleared)
    }

    private static func removeIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try ManualUpdateTransactionFiles.removeOwnedPath(url)
        } else if errno != ENOENT {
            throw ManualUpdateError.unsafePath("could not inspect a Maomao-owned clean-reset path")
        }
    }

    private static func removeStagingIfPresent(_ url: URL) throws {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw ManualUpdateError.unsafePath("private updater staging root is not a directory")
            }
            try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(url)
        } else if errno != ENOENT {
            throw ManualUpdateError.unsafePath("could not inspect private updater staging data")
        }
    }

    private static func writeNoImportMarker(_ manifest: ManualUpdateTransactionManifest) throws {
        let marker = URL(fileURLWithPath: manifest.noLegacyImportMarkerPath)
        try MaomaoDataPaths.createPrivateDirectory(marker.deletingLastPathComponent())
        try ManualUpdateTransactionFiles.writeDurably("no legacy Tan import\n", to: marker, replace: true)
    }

    private static func launchReplacement(_ manifest: ManualUpdateTransactionManifest) throws {
        let appURL = URL(fileURLWithPath: manifest.applicationPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path, "--args", "--noko-update-manifest", URL(fileURLWithPath: manifest.transactionDirectoryPath).appendingPathComponent("transaction.json").path, "--noko-update-journal", manifest.journalPath, "--noko-update-nonce", manifest.nonce]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ManualUpdateError.unavailable("macOS could not launch the replacement app.") }
    }

    private static func waitForReadiness(_ manifest: ManualUpdateTransactionManifest, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let journalURL = URL(fileURLWithPath: manifest.journalPath)
        while Date() < deadline {
            if let journal = try? readJournal(journalURL), journal.nonce == manifest.nonce {
                if journal.state == .appReady { return }
                if journal.state == .resetIncomplete {
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ManualUpdateError.unavailable("The replacement app did not complete its readiness handshake.")
    }

    static func rollback(
        _ manifest: ManualUpdateTransactionManifest,
        reason: String,
        validator: any ManualUpdateAppValidating = SystemManualUpdateAppValidator()
    ) throws {
        try writeJournal(manifest, .rollbackStarted, message: reason)
        let app = URL(fileURLWithPath: manifest.applicationPath)
        let backup = URL(fileURLWithPath: manifest.backupApplicationPath)
        let stage = URL(fileURLWithPath: manifest.stagedApplicationPath)
        let originalLocation: URL?
        if try directoryIdentityIfPresent(app) == manifest.installedApplicationIdentity { originalLocation = app }
        else if try directoryIdentityIfPresent(backup) == manifest.installedApplicationIdentity { originalLocation = backup }
        else if try directoryIdentityIfPresent(stage) == manifest.installedApplicationIdentity { originalLocation = stage }
        else { throw ManualUpdateError.unavailable("Rollback could not locate the original app. The transaction data is retained at \(manifest.transactionDirectoryPath).") }

        guard let originalLocation else {
            throw ManualUpdateError.unavailable("Rollback could not locate the original app. The transaction data is retained at \(manifest.transactionDirectoryPath).")
        }
        try validateInstalled(at: originalLocation, manifest: manifest, validator: validator)
        if originalLocation != app {
            var appInfo = stat()
            if lstat(app.path, &appInfo) == 0 {
                // Never exchange the saved original with an arbitrary directory
                // at the install path. Verify both bundles immediately before
                // the atomic swap, then verify the displaced candidate before
                // removing it.
                try validateCandidate(at: app, manifest: manifest, validator: validator)
                try ManualUpdateTransactionFiles.swapSameVolumeDirectories(app, originalLocation)
                try validateCandidate(at: originalLocation, manifest: manifest, validator: validator)
                try ManualUpdateTransactionFiles.removeApplicationBundleNoFollow(originalLocation)
            } else if errno == ENOENT {
                try ManualUpdateTransactionFiles.renameSameVolume(from: originalLocation, to: app, expectedSource: .directory)
            } else {
                throw ManualUpdateError.unsafePath("cannot inspect replacement during rollback")
            }
        }
        try validateInstalled(at: app, manifest: manifest, validator: validator)
        try writeJournal(manifest, .rollbackComplete, message: reason)
    }

    private static func launchRestoredApplication(_ manifest: ManualUpdateTransactionManifest) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", manifest.applicationPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManualUpdateError.unavailable("macOS could not relaunch the restored NokoCord app.")
        }
    }

    static func transactionHasSwapped(
        _ manifest: ManualUpdateTransactionManifest,
        validator: any ManualUpdateAppValidating = SystemManualUpdateAppValidator()
    ) throws -> Bool {
        let app = URL(fileURLWithPath: manifest.applicationPath)
        let stage = URL(fileURLWithPath: manifest.stagedApplicationPath)
        let backup = URL(fileURLWithPath: manifest.backupApplicationPath)
        let appIdentity = try directoryIdentityIfPresent(app)
        let stageIdentity = try directoryIdentityIfPresent(stage)
        let backupIdentity = try directoryIdentityIfPresent(backup)
        let identities = [appIdentity, stageIdentity, backupIdentity].compactMap { $0 }
        guard Set(identities).count == identities.count else {
            throw ManualUpdateError.unavailable("An application directory appears at multiple transaction paths; recovery files were retained.")
        }
        let appIsOriginal = appIdentity == manifest.installedApplicationIdentity
        let candidateIsLive = appIdentity == manifest.candidateApplicationIdentity
        let oldIsElsewhere = stageIdentity == manifest.installedApplicationIdentity
            || backupIdentity == manifest.installedApplicationIdentity

        if appIsOriginal {
            guard !oldIsElsewhere else {
                throw ManualUpdateError.unavailable("The original app appears at multiple transaction paths; recovery files were retained.")
            }
            return false
        }
        if candidateIsLive {
            try validateCandidate(at: app, manifest: manifest, validator: validator)
            return true
        }

        if appIdentity != nil {
            throw ManualUpdateError.unavailable("The install path contains an unexpected app; rollback stopped without replacing it.")
        }
        guard oldIsElsewhere else {
            throw ManualUpdateError.unavailable("The install path and transaction paths do not contain a verified app; recovery files were retained.")
        }
        return true
    }

    private static func directoryIdentityIfPresent(_ url: URL) throws -> ManualUpdateDirectoryIdentity? {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ManualUpdateError.unsafePath("could not inspect an application directory during recovery")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_ino != 0 else {
            throw ManualUpdateError.unsafePath("an application transaction path is not a directory")
        }
        return ManualUpdateDirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func writeJournal(_ manifest: ManualUpdateTransactionManifest, _ state: ManualUpdateJournalState, message: String? = nil) throws {
        try ManualUpdateTransactionFiles.writeDurably(
            ManualUpdateJournal(nonce: manifest.nonce, state: state, message: message),
            to: URL(fileURLWithPath: manifest.journalPath), replace: true
        )
    }

    static func readJournal(_ url: URL) throws -> ManualUpdateJournal {
        let descriptor = try ManualUpdateTransactionFiles.openRegularFileNoFollow(url.path)
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManualUpdateError.unsafePath("could not read update journal")
            }
            guard data.count + count <= 64 * 1024 else { throw ManualUpdateError.unsafePath("update journal exceeds size limit") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(ManualUpdateJournal.self, from: data)
    }

    private static func signatureString(_ signature: ManualUpdateSignature) -> String {
        switch signature { case .developerTeam(let team): "team:\(team)"; case .adHoc: "ad-hoc" }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isValidSignatureString(_ value: String) -> Bool {
        value == "ad-hoc" || value.range(of: "^team:[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
    }

    private static func validArchitectureList(_ architectures: [String]) -> Bool {
        return !architectures.isEmpty
            && Set(architectures).count == architectures.count
            && Set(architectures).isSubset(of: ManualUpdateArchitecture.supported)
    }

    private static func validateSameSignature(installed: String, candidate: String) throws {
        guard installed == candidate else { throw ManualUpdateError.invalidApplication("candidate and installed signing identities differ") }
    }
}
