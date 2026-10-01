import XCTest
@testable import NokoCordCore
import Darwin

final class ManualUpdaterTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        guard let temporaryPath = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw ManualUpdateError.unsafePath("cannot resolve system temporary directory")
        }
        defer { free(temporaryPath) }
        testRoot = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
            .appendingPathComponent("NokoCordManualUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot { try? FileManager.default.removeItem(at: testRoot) }
    }

    func testNumericVersionBuildClassificationAndAllowedOperation() throws {
        let installedVersion = try ManualUpdateVersion("1.3.9")
        let candidateVersion = try ManualUpdateVersion("1.4.0")
        XCTAssertLessThan(installedVersion, candidateVersion)

        let installedBuild = try ManualUpdateBuild("3")
        let newerBuild = try ManualUpdateBuild("4")
        XCTAssertLessThan(installedBuild, newerBuild)

        let marketingCandidate = candidate(version: "1.4.0", build: "1", classification: .newerMarketingVersion)
        XCTAssertTrue(marketingCandidate.permits(.update))
        XCTAssertFalse(marketingCandidate.permits(.cleanReinstall))
        let buildCandidate = candidate(version: "1.3.0", build: "4", classification: .newerBuild)
        XCTAssertTrue(buildCandidate.permits(.update))
        let sameCandidate = candidate(version: "1.3.0", build: "3", classification: .sameVersionCleanReinstall)
        XCTAssertTrue(sameCandidate.permits(.cleanReinstall))
        XCTAssertFalse(sameCandidate.permits(.update))
        let olderCandidate = candidate(version: "1.2.9", build: "99", classification: .older)
        XCTAssertFalse(olderCandidate.permits(.update))
        XCTAssertFalse(olderCandidate.permits(.cleanReinstall))
        XCTAssertEqual(olderCandidate.marketingVersion.description, "1.2.9")
        XCTAssertEqual(olderCandidate.installedMarketingVersion.description, "1.3.0")
    }

    func testNumericVersionAndBuildRejectMalformedValues() {
        for value in ["1.3", "1.3.0.1", "1.x.0", "1.-1.0", "1..0", "999999999999999999999.0.0"] {
            XCTAssertThrowsError(try ManualUpdateVersion(value), "\(value) must not parse")
        }
        for value in ["", "-1", "3.0", "build4", "999999999999999999999"] {
            XCTAssertThrowsError(try ManualUpdateBuild(value), "\(value) must not parse")
        }
    }

    func testStartupRecoveryRejectsFailedAndRollbackCandidateStates() {
        for state in [ManualUpdateJournalState.rollbackStarted, .rollbackComplete, .failed] {
            XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .update), "update must reject \(state)")
            XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .cleanReinstall), "clean reinstall must reject \(state)")
        }
        XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: .launchRequested, operation: .update))
        XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: .appReady, operation: .update))
        XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: .resetIncomplete, operation: .cleanReinstall))
        XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: .resetIncomplete, operation: .cleanReinstall, recoveryLockHeld: true))
        XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: .resetIncomplete, operation: .update))

        for state in [ManualUpdateJournalState.swapInProgress, .backupMoved, .replacementInstalled] {
            XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .update))
            XCTAssertFalse(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .cleanReinstall))
            XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .update, recoveryLockHeld: true))
            XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: state, operation: .cleanReinstall, recoveryLockHeld: true))
        }
        XCTAssertTrue(ManualUpdateStartupPolicy.mayCompleteCandidate(state: .launchRequested, operation: .update, recoveryLockHeld: false))
        XCTAssertFalse(ManualUpdateStartupPolicy.mayCompleteCandidate(state: .rollbackStarted, operation: .update, recoveryLockHeld: false))
        XCTAssertTrue(ManualUpdateStartupPolicy.mayCompleteCandidate(state: .webKitResetComplete, operation: .cleanReinstall, recoveryLockHeld: true))
        XCTAssertTrue(ManualUpdateStartupPolicy.needsExclusiveRecoveryLock(state: .cleanFilesCleared))
    }

    @MainActor
    func testStartupPreparationRunsBeforeRuntimeConstructionAndCompletion() async throws {
        let paths = MaomaoDataPaths(home: testRoot.appendingPathComponent("startup-order-home", isDirectory: true))
        let (manifest, manifestURL) = try makeTransactionManifest(paths: paths, operation: .cleanReinstall)
        let receipt = ManualUpdateStartupReceipt(
            manifest: manifest, manifestURL: manifestURL, cleanResetCompleted: true,
            recoveryLockDescriptor: nil, startupLockDescriptor: nil
        )
        var events: [String] = []

        let runtime = try await ManualUpdateStartupRecovery.createRuntimeAfterPreparation(
            prepare: {
                events.append("clean-reset-replay")
                return receipt
            },
            createRuntime: {
                events.append("construct-Tan-WebKit-Activity-runtime")
                return "ready"
            },
            complete: { _ in events.append("commit-update-readiness") }
        )

        XCTAssertEqual(runtime, "ready")
        XCTAssertEqual(events, ["clean-reset-replay", "construct-Tan-WebKit-Activity-runtime", "commit-update-readiness"])
    }

    func testCandidateStartupResetLockSerializesConcurrentLaunches() throws {
        let paths = MaomaoDataPaths(home: testRoot.appendingPathComponent("startup-lock-home", isDirectory: true))
        let (manifest, _) = try makeTransactionManifest(paths: paths, operation: .cleanReinstall)
        let first = try XCTUnwrap(ManualUpdateTransactionWorker.acquireStartupExclusionLock(manifest))
        defer { _ = flock(first, LOCK_UN); close(first) }

        XCTAssertNil(try ManualUpdateTransactionWorker.acquireStartupExclusionLock(manifest))

        _ = flock(first, LOCK_UN)
        let second = try XCTUnwrap(ManualUpdateTransactionWorker.acquireStartupExclusionLock(manifest))
        _ = flock(second, LOCK_UN)
        close(second)
    }

    func testEditionPathsAreExactAndRejectSymlinkedComponents() throws {
        let home = temporaryDirectory().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        XCTAssertEqual(paths.tanStorage.path, home.appendingPathComponent("Library/Application Support/NokoCord/com.shiikatan.nokocord.maomao/Tans").path)
        XCTAssertNotEqual(paths.tanStorage.path, home.appendingPathComponent("Library/Application Support/NokoCord/Tans").path)

        let linked = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: temporaryDirectory())
        XCTAssertThrowsError(try MaomaoDataPaths.validateNoSymlinkComponents(at: paths.tanStorage))
    }

    func testSameVolumeRenameAndDurableNoReplaceNeverOverwriteExistingData() throws {
        let parent = temporaryDirectory()
        let source = parent.appendingPathComponent("source", isDirectory: true)
        let destination = parent.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("value"))
        try Data("destination".utf8).write(to: destination.appendingPathComponent("value"))

        XCTAssertThrowsError(try ManualUpdateTransactionFiles.renameSameVolume(from: source, to: destination, expectedSource: .directory))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("value")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("value")), Data("destination".utf8))

        let record = parent.appendingPathComponent("record.json")
        try ManualUpdateTransactionFiles.writeDurably("first", to: record, replace: false)
        let firstValue = try Data(contentsOf: record)
        XCTAssertThrowsError(try ManualUpdateTransactionFiles.writeDurably("second", to: record, replace: false))
        XCTAssertEqual(try Data(contentsOf: record), firstValue)
        try ManualUpdateTransactionFiles.writeDurably("second", to: record, replace: true)
        XCTAssertNotEqual(try Data(contentsOf: record), firstValue)
    }

    func testRollbackDetectionRetainsUnexpectedInstallDirectory() throws {
        let home = testRoot.appendingPathComponent("rollback-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        let nonce = UUID().uuidString
        let installParent = testRoot.appendingPathComponent("rollback-install", isDirectory: true)
        let app = installParent.appendingPathComponent("NokoCord.app", isDirectory: true)
        let transaction = installParent.appendingPathComponent(".NokoCord-Update-\(nonce)", isDirectory: true)
        let stage = transaction.appendingPathComponent("Replacement.app", isDirectory: true)
        let backup = transaction.appendingPathComponent("Original.app", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try makeFixtureApp(at: stage, version: "1.4.0", build: "1")
        try makeFixtureApp(at: backup, version: "1.3.0", build: "4")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let unexpectedSentinel = app.appendingPathComponent("preserve-this-unrelated-directory")
        try Data("unrelated install data".utf8).write(to: unexpectedSentinel)

        let manifest = ManualUpdateTransactionManifest(
            schemaVersion: 1,
            nonce: nonce,
            operation: .update,
            process: ManualUpdateProcessIdentity(pid: getpid(), startSeconds: 1, startMicroseconds: 1),
            applicationPath: app.path,
            installedApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: backup),
            candidateApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: stage),
            transactionDirectoryPath: transaction.path,
            helperPath: transaction.appendingPathComponent("NokoCordUpdateHelper").path,
            helperSHA256: String(repeating: "a", count: 64),
            stagedApplicationPath: stage.path,
            backupApplicationPath: backup.path,
            journalPath: transaction.appendingPathComponent("journal.json").path,
            candidateBundleIdentifier: MaomaoDataPaths.bundleIdentifier,
            candidateEditionID: MaomaoDataPaths.editionID,
            candidateMarketingVersion: "1.4.0",
            candidateBuild: "1",
            candidateExecutableName: "NokoCord",
            candidateTreeSHA256: try ManualUpdateDigest.applicationTree(at: stage),
            candidateHelperSHA256: try ManualUpdateDigest.file(at: stage.appendingPathComponent("Contents/Helpers/NokoCordUpdateHelper")),
            candidateHelperSignature: "ad-hoc",
            candidateHelperArchitectures: ["arm64"],
            candidateSignature: "ad-hoc",
            candidateArchitectures: ["arm64"],
            installedMarketingVersion: "1.3.0",
            installedBuild: "4",
            installedExecutableName: "NokoCord",
            installedTreeSHA256: try ManualUpdateDigest.applicationTree(at: backup),
            installedSignature: "ad-hoc",
            installedArchitectures: ["arm64"],
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

        XCTAssertThrowsError(try ManualUpdateTransactionWorker.transactionHasSwapped(manifest))
        XCTAssertEqual(try Data(contentsOf: unexpectedSentinel), Data("unrelated install data".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testSameBuildCleanReinstallUsesDirectoryIdentityForRollback() throws {
        let home = testRoot.appendingPathComponent("same-build-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        let nonce = UUID().uuidString
        let installParent = testRoot.appendingPathComponent("same-build-install", isDirectory: true)
        let app = installParent.appendingPathComponent("NokoCord.app", isDirectory: true)
        let transaction = installParent.appendingPathComponent(".NokoCord-Update-\(nonce)", isDirectory: true)
        let stage = transaction.appendingPathComponent("Replacement.app", isDirectory: true)
        let backup = transaction.appendingPathComponent("Original.app", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try makeFixtureApp(at: app, version: "1.3.0", build: "3")
        try makeFixtureApp(at: stage, version: "1.3.0", build: "3")

        let installedDigest = try ManualUpdateDigest.applicationTree(at: app)
        let candidateDigest = try ManualUpdateDigest.applicationTree(at: stage)
        XCTAssertEqual(candidateDigest, installedDigest, "same-build Clean Reinstall fixture must exercise identical content digests")

        let manifest = ManualUpdateTransactionManifest(
            schemaVersion: 1,
            nonce: nonce,
            operation: .cleanReinstall,
            process: ManualUpdateProcessIdentity(pid: getpid(), startSeconds: 1, startMicroseconds: 1),
            applicationPath: app.path,
            installedApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: app),
            candidateApplicationIdentity: try ManualUpdateDirectoryIdentity.read(at: stage),
            transactionDirectoryPath: transaction.path,
            helperPath: transaction.appendingPathComponent("NokoCordUpdateHelper").path,
            helperSHA256: String(repeating: "a", count: 64),
            stagedApplicationPath: stage.path,
            backupApplicationPath: backup.path,
            journalPath: transaction.appendingPathComponent("journal.json").path,
            candidateBundleIdentifier: MaomaoDataPaths.bundleIdentifier,
            candidateEditionID: MaomaoDataPaths.editionID,
            candidateMarketingVersion: "1.3.0",
            candidateBuild: "3",
            candidateExecutableName: "NokoCord",
            candidateTreeSHA256: candidateDigest,
            candidateHelperSHA256: try ManualUpdateDigest.file(at: stage.appendingPathComponent("Contents/Helpers/NokoCordUpdateHelper")),
            candidateHelperSignature: "ad-hoc",
            candidateHelperArchitectures: ["arm64"],
            candidateSignature: "ad-hoc",
            candidateArchitectures: ["arm64"],
            installedMarketingVersion: "1.3.0",
            installedBuild: "3",
            installedExecutableName: "NokoCord",
            installedTreeSHA256: installedDigest,
            installedSignature: "ad-hoc",
            installedArchitectures: ["arm64"],
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

        XCTAssertFalse(try ManualUpdateTransactionWorker.transactionHasSwapped(manifest, validator: AcceptingValidator()))
        XCTAssertFalse(ManualUpdateStartupPolicy.candidateIsInstalled(identity: try ManualUpdateDirectoryIdentity.read(at: app), manifest: manifest))

        try ManualUpdateTransactionFiles.swapSameVolumeDirectories(app, stage)
        try ManualUpdateTransactionFiles.renameSameVolume(from: stage, to: backup, expectedSource: .directory)
        XCTAssertTrue(try ManualUpdateTransactionWorker.transactionHasSwapped(manifest, validator: AcceptingValidator()))
        XCTAssertTrue(ManualUpdateStartupPolicy.candidateIsInstalled(identity: try ManualUpdateDirectoryIdentity.read(at: app), manifest: manifest))
        XCTAssertTrue(ManualUpdateStartupPolicy.mayResumeCandidate(state: .swapInProgress, operation: .cleanReinstall, recoveryLockHeld: true))

        try ManualUpdateTransactionWorker.rollback(manifest, reason: "test recovery", validator: AcceptingValidator())
        XCTAssertEqual(try ManualUpdateDirectoryIdentity.read(at: app), manifest.installedApplicationIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try ManualUpdateTransactionWorker.readJournal(URL(fileURLWithPath: manifest.journalPath)).state, .rollbackComplete)
    }

    func testCleanResetRemovesOnlyMaomaoOwnedFilesAndToleratesFrameworkSymlinks() throws {
        let home = testRoot.appendingPathComponent("clean-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        let transaction = try makeTransactionManifest(paths: paths, operation: .cleanReinstall)

        try FileManager.default.createDirectory(at: paths.tanStorage, withIntermediateDirectories: true)
        try Data("tan".utf8).write(to: paths.tanStorage.appendingPathComponent("user.tan.json"))
        try FileManager.default.createDirectory(at: paths.cacheRoot, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: paths.cacheRoot.appendingPathComponent("cache.bin"))
        try FileManager.default.createDirectory(at: paths.preferencesPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preferences".utf8).write(to: paths.preferencesPlist)
        try FileManager.default.createDirectory(at: paths.savedApplicationState, withIntermediateDirectories: true)
        try Data("window state".utf8).write(to: paths.savedApplicationState.appendingPathComponent("state.plist"))
        try MaomaoDataPaths.createPrivateDirectory(paths.updateRoot)
        let helperFailure = ManualUpdateHelperFailureResult(
            nonce: transaction.manifest.nonce, operation: .cleanReinstall,
            status: .recoveryPending,
            installedVersion: "1.3.0", installedBuild: "4",
            candidateVersion: "1.3.0", candidateBuild: "4",
            message: "failure", recovery: "recovery retained", occurredAt: Date()
        )
        try ManualUpdateTransactionFiles.writeDurably(helperFailure, to: paths.helperFailureResult, replace: false)

        let candidate = paths.candidateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let framework = candidate.appendingPathComponent("unpacked/Maomao.app/Contents/Frameworks/Discord.framework", isDirectory: true)
        let versionA = framework.appendingPathComponent("Versions/A", isDirectory: true)
        try FileManager.default.createDirectory(at: versionA, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: versionA.appendingPathComponent("Discord"))
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path,
            withDestinationPath: "A"
        )

        try FileManager.default.createDirectory(at: paths.legacySharedTanStorage, withIntermediateDirectories: true)
        let sharedSentinel = paths.legacySharedTanStorage.appendingPathComponent("shared-user-data.txt")
        try Data("preserve shared legacy data".utf8).write(to: sharedSentinel)

        try ManualUpdateTransactionWorker.resumeCleanResetFiles(transaction.manifest, pathsOverride: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.tanStorage.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.tanStorage.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cacheRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferencesPlist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.savedApplicationState.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.candidateRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.noLegacyTanImportMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingCleanReset.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.helperFailureResult.path))
        XCTAssertEqual(try Data(contentsOf: sharedSentinel), Data("preserve shared legacy data".utf8))
        XCTAssertEqual(try ManualUpdateTransactionWorker.readJournal(URL(fileURLWithPath: transaction.manifest.journalPath)).state, .cleanFilesCleared)
    }

    @MainActor
    func testStartupWithoutPendingTransactionDoesNotClearWebKitOrPreferences() async throws {
        let home = testRoot.appendingPathComponent("startup-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        let resetter = RecordingWebDataResetter()
        let defaults = UserDefaults(suiteName: "ManualUpdaterTests.\(UUID().uuidString)")!
        let result = try await ManualUpdateStartupRecovery.prepare(
            runningAppURL: temporaryDirectory().appendingPathComponent("not-an-app.app"),
            paths: paths,
            arguments: ["NokoCord"],
            defaults: defaults,
            webDataResetter: resetter,
            credentialReset: { XCTFail("No transaction must not access Keychain") }
        )
        XCTAssertNil(result)
        XCTAssertFalse(resetter.wasCalled)
    }

    @MainActor
    func testCleanResetStopsBeforePreferencesAndWebKitWhenCredentialDeletionFails() async throws {
        let resetter = RecordingWebDataResetter()
        let defaults = UserDefaults(suiteName: "ManualUpdaterTests.\(UUID().uuidString)")!
        let key = "credential-reset-order"
        defaults.set("preserve", forKey: key)
        defer { defaults.removeObject(forKey: key) }
        var credentialResetWasCalled = false

        do {
            try await ManualUpdateStartupRecovery.clearCleanReinstallCredentialsPreferencesAndWebsiteData(
                defaults: defaults,
                webDataResetter: resetter,
                credentialReset: {
                    credentialResetWasCalled = true
                    throw DiscordSocialCredentialStoreError.invalidCredentialData
                }
            )
            XCTFail("Failed authorization cleanup must stop Clean Reinstall startup")
        } catch DiscordSocialCredentialStoreError.invalidCredentialData {
            XCTAssertTrue(credentialResetWasCalled)
            XCTAssertEqual(defaults.string(forKey: key), "preserve")
            XCTAssertFalse(resetter.wasCalled)
        }
    }

    @MainActor
    func testCleanPreferencesResetTargetsOnlyMaomaoDefaultsDomain() throws {
        let defaults = UserDefaults(suiteName: MaomaoDataPaths.bundleIdentifier)!
        let unrelatedDefaults = UserDefaults.standard
        let maomaoKey = "ManualUpdaterTests.\(UUID().uuidString)"
        let otherKey = "ManualUpdaterTests.other.\(UUID().uuidString)"
        defaults.set("erase", forKey: maomaoKey)
        unrelatedDefaults.set("keep", forKey: otherKey)
        defer { defaults.removeObject(forKey: maomaoKey); unrelatedDefaults.removeObject(forKey: otherKey) }

        try ManualUpdateStartupRecovery.clearMaomaoPreferences(using: defaults)

        XCTAssertNil(defaults.object(forKey: maomaoKey))
        XCTAssertEqual(unrelatedDefaults.string(forKey: otherKey), "keep")
    }

    func testStrictOwnedDataRemovalRejectsSymlinksWithoutDeletingTarget() throws {
        let parent = temporaryDirectory()
        let target = parent.appendingPathComponent("other-edition", isDirectory: true)
        let owned = parent.appendingPathComponent("maomao-data", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("preserve.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("linked"), withDestinationURL: target)

        XCTAssertThrowsError(try ManualUpdateTransactionFiles.removeOwnedPath(owned))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    }

    func testZipRejectsTraversalAndSpecialFiles() throws {
        let traversal = try archive(entries: [ZipEntry("../outside", bytes: Data("x".utf8))])
        defer { try? FileManager.default.removeItem(at: traversal) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(traversal))

        let special = try archive(entries: [ZipEntry("Maomao.app/", mode: 0o040755), ZipEntry("Maomao.app/Contents/FIFO", mode: 0o010644)])
        defer { try? FileManager.default.removeItem(at: special) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(special))
    }

    func testZipRejectsUnexpectedTopLevelEntriesAndMultipleBundles() throws {
        let unexpected = try archive(entries: [
            ZipEntry("Maomao.app/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/", mode: 0o040755),
            ZipEntry("README.txt", bytes: Data("not part of the app".utf8))
        ])
        defer { try? FileManager.default.removeItem(at: unexpected) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(unexpected))

        let multiple = try archive(entries: [
            ZipEntry("Maomao.app/", mode: 0o040755),
            ZipEntry("Other.app/", mode: 0o040755)
        ])
        defer { try? FileManager.default.removeItem(at: multiple) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(multiple))
    }

    func testZipRejectsEscapingAndCyclicFrameworkSymlinks() throws {
        let escaping = try frameworkArchive(links: [
            ("Maomao.app/Contents/Frameworks/Discord.framework/Versions/Current", "../../../../../../outside")
        ])
        defer { try? FileManager.default.removeItem(at: escaping) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(escaping))

        let cyclic = try frameworkArchive(links: [
            ("Maomao.app/Contents/Frameworks/Discord.framework/Versions/Current", "Other"),
            ("Maomao.app/Contents/Frameworks/Discord.framework/Versions/Other", "Current")
        ])
        defer { try? FileManager.default.removeItem(at: cyclic) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(cyclic))
    }

    func testActualDiscordFrameworkSymlinkPatternIsAcceptedAndExtracted() throws {
        let zip = try frameworkArchive(links: [
            ("Maomao.app/Contents/Frameworks/Discord.framework/Versions/Current", "A"),
            ("Maomao.app/Contents/Frameworks/Discord.framework/Discord", "Versions/Current/Discord")
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        let description = try ManualUpdateArchiveInspector.inspect(zip)
        XCTAssertEqual(description.symlinkTargets["Maomao.app/Contents/Frameworks/Discord.framework/Versions/Current"], "A")
        XCTAssertEqual(description.symlinkTargets["Maomao.app/Contents/Frameworks/Discord.framework/Discord"], "Versions/Current/Discord")

        let destination = temporaryDirectory().appendingPathComponent("extract", isDirectory: true)
        let app = try ManualUpdateArchiveInspector.extract(zip, to: destination, description: description)
        let frameworkFile = app.appendingPathComponent("Contents/Frameworks/Discord.framework/Discord")
        XCTAssertTrue(FileManager.default.fileExists(atPath: frameworkFile.path))
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.extract(zip, to: destination, description: description), "extraction must require a fresh destination")
    }

    func testDescriptorZipIsAcceptedAndLocalCentralMismatchIsRejected() throws {
        let root = ZipEntry("Maomao.app/", mode: 0o040755)
        let payload = ZipEntry("Maomao.app/Contents/value", bytes: Data("payload".utf8), dataDescriptor: true)
        let descriptorArchive = try archive(entries: [root, payload])
        defer { try? FileManager.default.removeItem(at: descriptorArchive) }
        let description = try ManualUpdateArchiveInspector.inspect(descriptorArchive)
        let extraction = temporaryDirectory().appendingPathComponent("descriptor-extract", isDirectory: true)
        _ = try ManualUpdateArchiveInspector.extract(descriptorArchive, to: extraction, description: description)

        let mismatchArchive = try archive(entries: [root, ZipEntry("Maomao.app/Contents/value", bytes: Data("payload".utf8), localCRCOverride: 0)])
        defer { try? FileManager.default.removeItem(at: mismatchArchive) }
        XCTAssertThrowsError(try ManualUpdateArchiveInspector.inspect(mismatchArchive), "local CRC disagreement must be rejected")
    }

    func testDittoProducedArchiveWithDataDescriptorsIsAccepted() throws {
        let app = temporaryDirectory().appendingPathComponent("DittoFixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: app.appendingPathComponent("Contents/MacOS/NokoCord"))
        try Data("fixture resource".utf8).write(to: app.appendingPathComponent("Contents/resource"))
        let zip = temporaryDirectory().appendingPathComponent("ditto.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        defer { try? FileManager.default.removeItem(at: zip) }

        let description = try ManualUpdateArchiveInspector.inspect(zip)
        XCTAssertEqual(description.applicationRootName, "DittoFixture.app")
        let extraction = temporaryDirectory().appendingPathComponent("ditto-extract", isDirectory: true)
        let extracted = try ManualUpdateArchiveInspector.extract(zip, to: extraction, description: description)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Contents/resource")), Data("fixture resource".utf8))
    }

    func testServiceReturnsTypedVersionClassificationsAndRevalidatesOperations() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("home", isDirectory: true)),
            validator: AcceptingValidator(), currentArchitecture: "arm64"
        )
        let cases: [(String, String, ManualUpdateClassification, ManualUpdateOperation)] = [
            ("1.4.0", "1", .newerMarketingVersion, .update),
            ("1.3.0", "4", .newerBuild, .update),
            ("1.3.0", "3", .sameVersionCleanReinstall, .cleanReinstall),
            ("1.2.9", "99", .older, .update)
        ]
        for (version, build, expectedClassification, operation) in cases {
            let zip = try appArchive(version: version, build: build)
            defer { try? FileManager.default.removeItem(at: zip) }
            let candidate = try await service.inspect(zipURL: zip)
            XCTAssertEqual(candidate.classification, expectedClassification)
            XCTAssertEqual(candidate.installedMarketingVersion.description, "1.3.0")
            XCTAssertEqual(candidate.installedBuild.description, "3")
            XCTAssertEqual(candidate.marketingVersion.description, version)
            XCTAssertEqual(candidate.build.description, build)
            if expectedClassification == .older {
                XCTAssertFalse(candidate.permits(.update))
                do {
                    try await service.revalidate(candidate, operation: operation)
                    XCTFail("older version should return a typed downgrade error")
                } catch let error as ManualUpdateError {
                    guard case .versionRejected(_, _, let candidateVersion, let candidateBuild) = error else {
                        return XCTFail("expected typed version rejection, got \(error)")
                    }
                    XCTAssertEqual(candidateVersion, version)
                    XCTAssertEqual(candidateBuild, build)
                }
            } else {
                try await service.revalidate(candidate, operation: operation)
            }
        }
    }

    func testServiceRejectsWrongBundleMalformedMetadataAndMissingExecutable() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("invalid-candidate-home", isDirectory: true)),
            validator: AcceptingValidator(), currentArchitecture: "arm64"
        )
        let malformedInfo = Data("not a property list".utf8)
        let invalidVersionInfo = try appInfo(version: "1.3", build: "4")
        let candidates = [
            (try appArchive(version: "1.4.0", build: "1", bundleIdentifier: "com.example.other"), ManualUpdateError.unsupportedEdition),
            (try appArchive(version: "1.4.0", build: "1", infoData: malformedInfo), ManualUpdateError.invalidApplication("application identity or version metadata is missing")),
            (try appArchive(version: "1.4.0", build: "1", infoData: invalidVersionInfo), ManualUpdateError.invalidApplication("invalid numeric marketing version")),
            (try appArchive(version: "1.4.0", build: "1", includeExecutable: false), ManualUpdateError.invalidApplication("the declared executable is missing or not executable"))
        ]
        defer { candidates.forEach { try? FileManager.default.removeItem(at: $0.0) } }

        for (zip, expectedError) in candidates {
            do {
                _ = try await service.inspect(zipURL: zip)
                XCTFail("invalid candidate should be rejected: \(zip.lastPathComponent)")
            } catch let error as ManualUpdateError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("unexpected error for invalid candidate: \(error)")
            }
        }
    }

    func testServiceRejectsArchitectureIncompatibleCandidateAndHelper() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("architecture-home", isDirectory: true)),
            validator: CandidateArchitectureMismatchValidator(installedAppPath: installed.path),
            currentArchitecture: "arm64"
        )
        let zip = try appArchive(version: "1.4.0", build: "1")
        defer { try? FileManager.default.removeItem(at: zip) }

        do {
            _ = try await service.inspect(zipURL: zip)
            XCTFail("candidate and helper without arm64 support must be rejected")
        } catch let error as ManualUpdateError {
            XCTAssertEqual(error, .invalidApplication("the bundled updater helper signature or architecture does not match its app"))
        }
    }

    func testServiceRejectsUnsupportedExtraArchitectureDuringInspection() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("unsupported-architecture-home", isDirectory: true)),
            validator: UnsupportedExtraArchitectureValidator(installedAppPath: installed.path),
            currentArchitecture: "arm64"
        )
        let zip = try appArchive(version: "1.4.0", build: "1")
        defer { try? FileManager.default.removeItem(at: zip) }

        do {
            _ = try await service.inspect(zipURL: zip)
            XCTFail("candidate with an unsupported extra slice must be rejected during inspection")
        } catch let error as ManualUpdateError {
            XCTAssertEqual(error, .invalidApplication("the app or updater helper includes an unsupported architecture"))
        }
    }

    func testHelperFailureResultCanBeReadAndDismissed() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let paths = MaomaoDataPaths(home: testRoot.appendingPathComponent("helper-failure-home", isDirectory: true))
        try MaomaoDataPaths.createPrivateDirectory(paths.updateRoot)
        let transaction = try makeTransactionManifest(paths: paths, operation: .update)
        try ManualUpdateTransactionWorker.persistFailureResult(
            transaction.manifest,
            error: ManualUpdateError.unavailable("The replacement app did not become ready."),
            status: .previousAppRestored,
            recovery: "The previous app was restored.",
            pathsOverride: paths
        )
        try FileManager.default.removeItem(at: transaction.manifestURL.deletingLastPathComponent())
        let service = ManualUpdateService(currentAppURL: installed, paths: paths, validator: AcceptingValidator(), currentArchitecture: "arm64")

        let pending = try await service.pendingHelperFailure()
        XCTAssertEqual(pending?.nonce, transaction.manifest.nonce)
        XCTAssertEqual(pending?.status, .previousAppRestored)
        XCTAssertEqual(pending?.candidateVersion, "1.3.0")
        XCTAssertEqual(pending?.recovery, "The previous app was restored.")
        XCTAssertTrue(pending?.message.contains("did not become ready") == true)
        try ManualUpdateTransactionWorker.clearFailureResult(for: transaction.manifest, pathsOverride: paths)
        let clearedOnSuccess = try await service.pendingHelperFailure()
        XCTAssertNil(clearedOnSuccess)
        try ManualUpdateTransactionWorker.persistFailureResult(
            transaction.manifest,
            error: ManualUpdateError.unavailable("The replacement app did not become ready."),
            status: .previousAppRestored,
            recovery: "The previous app was restored.",
            pathsOverride: paths
        )
        try await service.dismissHelperFailure(nonce: transaction.manifest.nonce)
        let dismissed = try await service.pendingHelperFailure()
        XCTAssertNil(dismissed)
        do {
            try await service.dismissHelperFailure(nonce: transaction.manifest.nonce)
            XCTFail("dismissing a missing result should fail")
        } catch ManualUpdateError.staleCandidate {
        }
        let staleFailure = ManualUpdateHelperFailureResult(
            nonce: UUID().uuidString, operation: .update,
            status: .previousAppRestored,
            installedVersion: "1.3.0", installedBuild: "3",
            candidateVersion: "1.3.0", candidateBuild: "4",
            message: "older failure", recovery: "old app restored", occurredAt: Date()
        )
        try ManualUpdateTransactionFiles.writeDurably(staleFailure, to: paths.helperFailureResult, replace: false)
        try ManualUpdateTransactionWorker.clearPreviousFailureResult(for: transaction.manifest, pathsOverride: paths)
        let staleNotice = try await service.pendingHelperFailure()
        XCTAssertNil(staleNotice)
    }

    func testNormalUpdateSkipsCleanResetAndPreservesPersistentData() throws {
        let home = testRoot.appendingPathComponent("normal-update-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = MaomaoDataPaths(home: home)
        let transaction = try makeTransactionManifest(paths: paths, operation: .update)
        try FileManager.default.createDirectory(at: paths.tanStorage, withIntermediateDirectories: true)
        try Data("keep tan state".utf8).write(to: paths.tanStorage.appendingPathComponent("state.json"))
        try FileManager.default.createDirectory(at: paths.cacheRoot, withIntermediateDirectories: true)
        try Data("keep cache".utf8).write(to: paths.cacheRoot.appendingPathComponent("cache.bin"))
        try FileManager.default.createDirectory(at: paths.preferencesPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep preferences".utf8).write(to: paths.preferencesPlist)
        try FileManager.default.createDirectory(at: paths.savedApplicationState, withIntermediateDirectories: true)
        try Data("keep window state".utf8).write(to: paths.savedApplicationState.appendingPathComponent("state.plist"))
        try FileManager.default.createDirectory(at: paths.candidateRoot, withIntermediateDirectories: true)
        let stagedCandidate = paths.candidateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagedCandidate, withIntermediateDirectories: true)

        XCTAssertFalse(try ManualUpdateTransactionWorker.applyCleanResetIfNeeded(transaction.manifest, pathsOverride: paths))
        XCTAssertEqual(try Data(contentsOf: paths.tanStorage.appendingPathComponent("state.json")), Data("keep tan state".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.cacheRoot.appendingPathComponent("cache.bin")), Data("keep cache".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.preferencesPlist), Data("keep preferences".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.savedApplicationState.appendingPathComponent("state.plist")), Data("keep window state".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedCandidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingCleanReset.path))
    }

    func testServiceRejectsInstalledAppMutationAfterInspection() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("home", isDirectory: true)),
            validator: AcceptingValidator(), currentArchitecture: "arm64"
        )
        let zip = try appArchive(version: "1.4.0", build: "1")
        defer { try? FileManager.default.removeItem(at: zip) }
        let candidate = try await service.inspect(zipURL: zip)
        try Data("mutated executable".utf8).write(to: installed.appendingPathComponent("Contents/MacOS/NokoCord"))
        do {
            try await service.revalidate(candidate, operation: .update)
            XCTFail("changed installed app should invalidate inspection")
        } catch let error as ManualUpdateError {
            XCTAssertEqual(error, .staleCandidate)
        }
    }

    func testServiceRejectsM12BaselineEvenWhenCandidateIsNewer() async throws {
        let installed = try makeInstalledApp(version: "1.2.9", build: "99")
        let service = ManualUpdateService(
            currentAppURL: installed,
            paths: MaomaoDataPaths(home: testRoot.appendingPathComponent("home", isDirectory: true)),
            validator: AcceptingValidator(), currentArchitecture: "arm64"
        )
        let zip = try appArchive(version: "1.4.0", build: "10")
        defer { try? FileManager.default.removeItem(at: zip) }
        let candidate = try await service.inspect(zipURL: zip)
        XCTAssertEqual(candidate.classification, .unsupportedBaseline)
        XCTAssertFalse(candidate.permits(.update))
        do {
            try await service.revalidate(candidate, operation: .update)
            XCTFail("M1.2 must not be upgraded through the manual M1.3 updater")
        } catch let error as ManualUpdateError {
            guard case .baselineUnsupported(let currentVersion, let currentBuild, let candidateVersion, let candidateBuild) = error else {
                return XCTFail("expected unsupported-baseline error, got \(error)")
            }
            XCTAssertEqual(currentVersion, "1.2.9")
            XCTAssertEqual(currentBuild, "99")
            XCTAssertEqual(candidateVersion, "1.4.0")
            XCTAssertEqual(candidateBuild, "10")
        }
    }

    func testNewAndFailedInspectionDiscardStaleCandidates() async throws {
        let installed = try makeInstalledApp(version: "1.3.0", build: "3")
        let paths = MaomaoDataPaths(home: testRoot.appendingPathComponent("home", isDirectory: true))
        let service = ManualUpdateService(
            currentAppURL: installed, paths: paths,
            validator: AcceptingValidator(), currentArchitecture: "arm64"
        )
        let firstZip = try appArchive(version: "1.4.0", build: "1")
        defer { try? FileManager.default.removeItem(at: firstZip) }
        _ = try await service.inspect(zipURL: firstZip)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.candidateRoot.path).count, 1)

        let invalidZip = temporaryDirectory().appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: invalidZip)
        defer { try? FileManager.default.removeItem(at: invalidZip) }
        do {
            _ = try await service.inspect(zipURL: invalidZip)
            XCTFail("invalid selection should fail")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.candidateRoot.path).count, 0)
    }

    private func candidate(version: String, build: String, classification: ManualUpdateClassification) -> ManualUpdateCandidate {
        ManualUpdateCandidate(
            archiveSHA256: String(repeating: "a", count: 64), applicationTreeSHA256: String(repeating: "b", count: 64),
            stagedApplicationURL: URL(fileURLWithPath: "/tmp/Maomao.app"), bundleIdentifier: MaomaoDataPaths.bundleIdentifier,
            editionID: MaomaoDataPaths.editionID, marketingVersion: try! ManualUpdateVersion(version),
            build: try! ManualUpdateBuild(build), installedMarketingVersion: try! ManualUpdateVersion("1.3.0"),
            installedBuild: try! ManualUpdateBuild("3"), installedApplicationTreeSHA256: String(repeating: "c", count: 64),
            installedSignature: .adHoc, installedArchitectures: ["arm64"], executableName: "NokoCord", architectures: ["arm64"],
            signature: .adHoc, helperSHA256: String(repeating: "d", count: 64), helperArchitectures: ["arm64"],
            helperSignature: .adHoc, classification: classification
        )
    }

    private struct ZipEntry {
        let path: String
        let bytes: Data
        let mode: UInt32
        let dataDescriptor: Bool
        let localCRCOverride: UInt32?
        init(_ path: String, bytes: Data = Data(), mode: UInt32? = nil, dataDescriptor: Bool = false, localCRCOverride: UInt32? = nil) {
            self.path = path
            self.bytes = bytes
            self.dataDescriptor = dataDescriptor
            self.localCRCOverride = localCRCOverride
            if let mode { self.mode = mode }
            else { self.mode = path.hasSuffix("/") ? 0o040755 : 0o100644 }
        }
    }

    private struct AcceptingValidator: ManualUpdateAppValidating {
        func validate(appURL: URL, executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(signature: .adHoc, architectures: ["arm64"])
        }

        func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(signature: .adHoc, architectures: ["arm64"])
        }
    }

    private struct CandidateArchitectureMismatchValidator: ManualUpdateAppValidating {
        let installedAppPath: String

        func validate(appURL: URL, executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(signature: .adHoc, architectures: appURL.path == installedAppPath ? ["arm64"] : ["x86_64"])
        }

        func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(signature: .adHoc, architectures: executableURL.path.hasPrefix(installedAppPath + "/") ? ["arm64"] : ["x86_64"])
        }
    }

    private struct UnsupportedExtraArchitectureValidator: ManualUpdateAppValidating {
        let installedAppPath: String
        private let unsupportedArchitectures: Set<String> = ["arm64", "riscv64"]

        func validate(appURL: URL, executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(
                signature: .adHoc,
                architectures: appURL.path == installedAppPath ? ["arm64"] : unsupportedArchitectures
            )
        }

        func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation {
            ManualUpdateAppValidation(
                signature: .adHoc,
                architectures: executableURL.path.hasPrefix(installedAppPath + "/") ? ["arm64"] : unsupportedArchitectures
            )
        }
    }

    private func makeInstalledApp(version: String, build: String) throws -> URL {
        let app = testRoot.appendingPathComponent("installed/Maomao.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("_CodeSignature", isDirectory: true), withIntermediateDirectories: true)
        try appInfo(version: version, build: build).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("signature fixture".utf8).write(to: contents.appendingPathComponent("_CodeSignature/CodeResources"))
        let executable = contents.appendingPathComponent("MacOS/NokoCord")
        try Data("executable \(version) \(build)".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = contents.appendingPathComponent("Helpers/NokoCordUpdateHelper")
        try Data("helper executable \(version) \(build)".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return app
    }

    private func makeFixtureApp(at app: URL, version: String, build: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers", isDirectory: true), withIntermediateDirectories: true)
        try appInfo(version: version, build: build).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/NokoCord")
        try Data("fixture executable \(version) \(build)".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = contents.appendingPathComponent("Helpers/NokoCordUpdateHelper")
        try Data("fixture helper \(version) \(build)".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    private func appArchive(
        version: String,
        build: String,
        bundleIdentifier: String = MaomaoDataPaths.bundleIdentifier,
        infoData: Data? = nil,
        includeExecutable: Bool = true
    ) throws -> URL {
        let root = "Maomao.app"
        let info: Data
        if let infoData { info = infoData }
        else { info = try appInfo(version: version, build: build, bundleIdentifier: bundleIdentifier) }
        var entries = [
            ZipEntry(root + "/", mode: 0o040755),
            ZipEntry(root + "/Contents/", mode: 0o040755),
            ZipEntry(root + "/Contents/MacOS/", mode: 0o040755),
            ZipEntry(root + "/Contents/_CodeSignature/", mode: 0o040755),
            ZipEntry(root + "/Contents/Info.plist", bytes: info),
            ZipEntry(root + "/Contents/MacOS/NokoCord", bytes: Data("executable \(version) \(build)".utf8), mode: 0o100755),
            ZipEntry(root + "/Contents/Helpers/", mode: 0o040755),
            ZipEntry(root + "/Contents/Helpers/NokoCordUpdateHelper", bytes: Data("helper executable \(version) \(build)".utf8), mode: 0o100755),
            ZipEntry(root + "/Contents/_CodeSignature/CodeResources", bytes: Data("signature fixture".utf8))
        ]
        if !includeExecutable { entries.removeAll { $0.path == root + "/Contents/MacOS/NokoCord" } }
        return try archive(entries: entries)
    }

    private func appInfo(
        version: String,
        build: String,
        bundleIdentifier: String = MaomaoDataPaths.bundleIdentifier
    ) throws -> Data {
        let values: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "NokoEditionID": MaomaoDataPaths.editionID,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "NokoCord"
        ]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private func frameworkArchive(links: [(String, String)]) throws -> URL {
        let entries = [
            ZipEntry("Maomao.app/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/Frameworks/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/Frameworks/Discord.framework/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/Frameworks/Discord.framework/Versions/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/Frameworks/Discord.framework/Versions/A/", mode: 0o040755),
            ZipEntry("Maomao.app/Contents/Frameworks/Discord.framework/Versions/A/Discord", bytes: Data("sdk".utf8))
        ] + links.map { ZipEntry($0.0, bytes: Data($0.1.utf8), mode: 0o120777) }
        return try archive(entries: entries)
    }

    private func archive(entries: [ZipEntry]) throws -> URL {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let offset = UInt32(local.count)
            let crc = crc32(entry.bytes)
            let flags: UInt16 = entry.dataDescriptor ? 0x0808 : 0x0800
            local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20)); local.appendLE(flags)
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(entry.dataDescriptor ? 0 : (entry.localCRCOverride ?? crc))
            local.appendLE(entry.dataDescriptor ? 0 : UInt32(entry.bytes.count)); local.appendLE(entry.dataDescriptor ? 0 : UInt32(entry.bytes.count))
            local.appendLE(UInt16(name.count)); local.appendLE(UInt16(0)); local.append(name); local.append(entry.bytes)
            if entry.dataDescriptor {
                local.appendLE(UInt32(0x08074b50)); local.appendLE(crc)
                local.appendLE(UInt32(entry.bytes.count)); local.appendLE(UInt32(entry.bytes.count))
            }

            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16((3 << 8) | 20)); central.appendLE(UInt16(20))
            central.appendLE(flags); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc); central.appendLE(UInt32(entry.bytes.count)); central.appendLE(UInt32(entry.bytes.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(entry.mode << 16); central.appendLE(offset); central.append(name)
        }
        let centralOffset = UInt32(local.count)
        let centralSize = UInt32(central.count)
        var data = local
        data.append(central)
        data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(entries.count)); data.appendLE(UInt16(entries.count)); data.appendLE(centralSize)
        data.appendLE(centralOffset); data.appendLE(UInt16(0))
        let url = temporaryDirectory().appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }

    private func temporaryDirectory() -> URL {
        let directory = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTransactionManifest(
        paths: MaomaoDataPaths,
        operation: ManualUpdateOperation
    ) throws -> (manifest: ManualUpdateTransactionManifest, manifestURL: URL) {
        let nonce = UUID().uuidString
        let installationParent = temporaryDirectory()
        let appURL = installationParent.appendingPathComponent("NokoCord.app", isDirectory: true)
        let transactionDirectory = installationParent.appendingPathComponent(".NokoCord-Update-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        let manifestURL = transactionDirectory.appendingPathComponent("transaction.json")
        let manifest = ManualUpdateTransactionManifest(
            schemaVersion: 1,
            nonce: nonce,
            operation: operation,
            process: ManualUpdateProcessIdentity(pid: getpid(), startSeconds: 1, startMicroseconds: 1),
            applicationPath: appURL.path,
            installedApplicationIdentity: ManualUpdateDirectoryIdentity(device: 1, inode: 1),
            candidateApplicationIdentity: ManualUpdateDirectoryIdentity(device: 1, inode: 2),
            transactionDirectoryPath: transactionDirectory.path,
            helperPath: transactionDirectory.appendingPathComponent("NokoCordUpdateHelper").path,
            helperSHA256: String(repeating: "a", count: 64),
            stagedApplicationPath: transactionDirectory.appendingPathComponent("Replacement.app").path,
            backupApplicationPath: transactionDirectory.appendingPathComponent("Original.app").path,
            journalPath: transactionDirectory.appendingPathComponent("journal.json").path,
            candidateBundleIdentifier: MaomaoDataPaths.bundleIdentifier,
            candidateEditionID: MaomaoDataPaths.editionID,
            candidateMarketingVersion: "1.3.0",
            candidateBuild: "4",
            candidateExecutableName: "NokoCord",
            candidateTreeSHA256: String(repeating: "b", count: 64),
            candidateHelperSHA256: String(repeating: "d", count: 64),
            candidateHelperSignature: "ad-hoc",
            candidateHelperArchitectures: ["arm64"],
            candidateSignature: "ad-hoc",
            candidateArchitectures: ["arm64"],
            installedMarketingVersion: "1.3.0",
            installedBuild: "4",
            installedExecutableName: "NokoCord",
            installedTreeSHA256: String(repeating: "c", count: 64),
            installedSignature: "ad-hoc",
            installedArchitectures: ["arm64"],
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
        return (manifest, manifestURL)
    }

    @MainActor
    private final class RecordingWebDataResetter: ManualUpdateWebDataResetting {
        private(set) var wasCalled = false
        func clearWebsiteData() async throws { wasCalled = true }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
