import XCTest
import Security
@testable import NokoCordCore

private actor PublicationDrainFlag {
    private(set) var isDrained = false
    func markDrained() { isDrained = true }
}

final class DiscordSocialCredentialStoreTests: XCTestCase {
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
