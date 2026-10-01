import XCTest
import Security
@testable import NokoCordCore

private actor PublicationDrainFlag {
    private(set) var isDrained = false
    func markDrained() { isDrained = true }
}

private actor RecordingCredentialStore: DiscordSocialCredentialStoring {
    private(set) var removeCount = 0
    var shouldFail = false

    func load() async throws -> DiscordSocialCredentials? { nil }
    func save(_ credentials: DiscordSocialCredentials) async throws {}
    func remove() async throws {
        removeCount += 1
        if shouldFail { throw DiscordSocialCredentialStoreError.invalidCredentialData }
    }
    func failRemoval() { shouldFail = true }
}

final class DiscordSocialCredentialStoreTests: XCTestCase {
    func testUnconfiguredOrInvalidApplicationIdentifiersAreRejected() {
        for value in [nil, "", "0", "$(NOKO_DISCORD_APPLICATION_ID)", "-1", "+1", " 42", "42 ", "18446744073709551616"] as [String?] {
            XCTAssertNil(DiscordSocialConfiguration.parseApplicationID(value))
        }
        XCTAssertNil(DiscordSocialConfiguration.parseApplicationID(42))
        XCTAssertEqual(DiscordSocialConfiguration.parseApplicationID("42"), 42)
    }

    func testKeychainServiceSeparatesApplications() {
        XCTAssertNotEqual(
            DiscordSocialConfiguration.credentialService(applicationID: 42),
            DiscordSocialConfiguration.credentialService(applicationID: 43)
        )
        XCTAssertNotEqual(DiscordSocialConfiguration.credentialService(applicationID: 42), KeychainDiscordSocialCredentialStore.productionService)
    }

    func testCleanReinstallRemovesOnlyOwnedAuthorizationNamespace() async throws {
        let current = RecordingCredentialStore()
        let other = RecordingCredentialStore()
        let legacy = RecordingCredentialStore()
        let unrelated = RecordingCredentialStore()
        let currentService = DiscordSocialConfiguration.credentialService(applicationID: 42)
        let otherService = DiscordSocialConfiguration.credentialService(applicationID: 43)
        let unrelatedService = "com.example.unrelated"
        let stores: [String: RecordingCredentialStore] = [
            currentService: current,
            otherService: other,
            KeychainDiscordSocialCredentialStore.productionService: legacy,
            unrelatedService: unrelated
        ]
        try await DiscordSocialCredentialReset.removeForCleanReinstall(
            authorizationServices: { Array(stores.keys) + [KeychainDiscordSocialCredentialStore.productionService + ".invalid"] },
            storeForService: { stores[$0]! }
        )
        let currentCount = await current.removeCount
        let legacyCount = await legacy.removeCount
        let otherCount = await other.removeCount
        let unrelatedCount = await unrelated.removeCount
        XCTAssertEqual(currentCount, 1)
        XCTAssertEqual(legacyCount, 1)
        XCTAssertEqual(otherCount, 1)
        XCTAssertEqual(unrelatedCount, 0)
    }

    func testCleanReinstallKeychainFailurePreventsResetCompletion() async throws {
        let legacy = RecordingCredentialStore()
        let current = RecordingCredentialStore()
        await legacy.failRemoval()
        let currentService = DiscordSocialConfiguration.credentialService(applicationID: 42)
        let stores: [String: RecordingCredentialStore] = [
            currentService: current,
            KeychainDiscordSocialCredentialStore.productionService: legacy
        ]
        do {
            try await DiscordSocialCredentialReset.removeForCleanReinstall(
                authorizationServices: { Array(stores.keys) },
                storeForService: { stores[$0]! }
            )
            XCTFail("A failed Keychain deletion must keep startup recovery pending")
        } catch DiscordSocialCredentialStoreError.invalidCredentialData {
            let currentCount = await current.removeCount
            let legacyCount = await legacy.removeCount
            XCTAssertEqual(currentCount, 0)
            XCTAssertEqual(legacyCount, 1)
        }
    }

    func testCleanReinstallKeychainEnumerationFailureDeletesNothing() async throws {
        let store = RecordingCredentialStore()
        do {
            try await DiscordSocialCredentialReset.removeForCleanReinstall(
                authorizationServices: { throw DiscordSocialCredentialStoreError.invalidCredentialData },
                storeForService: { _ in store }
            )
            XCTFail("Failed Keychain inventory must keep startup recovery pending")
        } catch DiscordSocialCredentialStoreError.invalidCredentialData {
            let count = await store.removeCount
            XCTAssertEqual(count, 0)
        }
    }

    func testKeychainStoreSavesReplacesLoadsAndRemovesTokenPair() async throws {
        let service = "com.shiikatan.nokocord.tests.\(UUID().uuidString)"
        let store = KeychainDiscordSocialCredentialStore(service: service)
        let first = DiscordSocialCredentials(
            accessToken: "access-test-one",
            refreshToken: "refresh-test-one",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let rotated = DiscordSocialCredentials(
            accessToken: "access-test-two",
            refreshToken: "refresh-test-two",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let initial: DiscordSocialCredentials?
        do {
            initial = try await store.load()
        } catch DiscordSocialCredentialStoreError.keychainStatus(let status)
            where status == errSecParam || status == errSecNotAvailable {
            throw XCTSkip("This test process has no usable macOS Keychain search list.")
        }
        XCTAssertNil(initial)
        try await store.save(first)
        let savedFirst = try await store.load()
        XCTAssertEqual(savedFirst, first)
        try await store.save(rotated)
        let savedRotated = try await store.load()
        XCTAssertEqual(savedRotated, rotated)
        try await store.remove()
        let afterRemoval = try await store.load()
        XCTAssertNil(afterRemoval)
    }

    func testPublicationGateBlocksTheDisconnectedTransportDuringConnection() {
        let gate = DiscordSocialPublicationGate()
        var mode = gate.currentMode()
        XCTAssertEqual(mode, .desktopRPC)

        gate.beginConnecting(sessionGeneration: 1)
        mode = gate.currentMode()
        XCTAssertEqual(mode, .connecting)

        XCTAssertTrue(gate.markReady(sessionGeneration: 1))
        mode = gate.currentMode()
        XCTAssertEqual(mode, .authenticated)

        gate.useDesktopRPC(sessionGeneration: 1)
        mode = gate.currentMode()
        XCTAssertEqual(mode, .desktopRPC)

        gate.beginConnecting(sessionGeneration: 2)
        XCTAssertFalse(gate.markReady(sessionGeneration: 1))
        XCTAssertEqual(gate.currentMode(), .connecting)
        gate.beginConnecting(sessionGeneration: 1)
        XCTAssertEqual(gate.currentMode(), .connecting)
        XCTAssertTrue(gate.markReady(sessionGeneration: 2))
    }

    func testPublicationDrainWaitsForReservedUpdatesBeforeDisconnect() async throws {
        let gate = DiscordSocialPublicationGate()
        let flag = PublicationDrainFlag()
        XCTAssertTrue(gate.beginPublication())
        gate.beginConnecting(sessionGeneration: 1)
        XCTAssertFalse(gate.beginPublication())

        let drainTask = Task {
            await gate.waitForPublicationsToDrain()
            await flag.markDrained()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let drainedBeforeRelease = await flag.isDrained
        XCTAssertFalse(drainedBeforeRelease)

        gate.endPublication()
        await drainTask.value
        let drainedAfterRelease = await flag.isDrained
        XCTAssertTrue(drainedAfterRelease)
    }

    func testClearDeferredDuringReconnectBlocksWritesUntilReadyClearCompletes() {
        let gate = DiscordSocialPublicationGate()
        gate.beginConnecting(sessionGeneration: 1)
        XCTAssertFalse(gate.beginPublication())
        XCTAssertTrue(gate.deferClearIfBlocked())

        XCTAssertTrue(gate.markReady(sessionGeneration: 1))
        XCTAssertFalse(gate.beginPublication())
        XCTAssertTrue(gate.beginDeferredClear())
        XCTAssertFalse(gate.beginPublication())

        gate.finishDeferredClear(succeeded: false)
        XCTAssertFalse(gate.beginPublication())
        XCTAssertTrue(gate.beginDeferredClear())
        gate.finishDeferredClear(succeeded: true)
        XCTAssertTrue(gate.beginPublication())
        gate.endPublication()
    }
}
