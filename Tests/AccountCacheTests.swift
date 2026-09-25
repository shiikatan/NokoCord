import Foundation
import XCTest
@testable import NokoCordCore

final class AccountCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-AccountCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func account() -> DiscordUser {
        DiscordUser(id: "fixture-user", username: "Fixture User", globalName: nil, avatar: nil)
    }

    private func guild() -> DiscordGuild {
        DiscordGuild(id: "fixture-guild", name: "Fixture Guild", icon: nil, owner: true, permissions: "0")
    }

    private func makeCache(in directory: URL, now: Date) -> AccountCache {
        AccountCache(directory: directory, now: { now })
    }

    func testRoundTripUsesInjectedTimestamp() async throws {
        let directory = try makeDirectory()
        let cache = makeCache(in: directory, now: now)

        try await cache.save(account: account(), guilds: [guild()])
        let loaded = try await cache.load()

        XCTAssertEqual(loaded?.version, 1)
        XCTAssertEqual(loaded?.account, account())
        XCTAssertEqual(loaded?.guilds, [guild()])
        XCTAssertEqual(loaded?.savedAt, now)
    }

    func testExactAgeAndFutureBoundariesAreRejectedAndCleared() async throws {
        let directory = try makeDirectory()
        let cache = makeCache(in: directory, now: now)
        let file = directory.appendingPathComponent("account-v1.json")

        try await cache.save(account: account(), guilds: [guild()])
        let expired = makeCache(in: directory, now: now.addingTimeInterval(86_400))
        let expiredSnapshot = try await expired.load()
        XCTAssertNil(expiredSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try await cache.save(account: account(), guilds: [guild()])
        let future = makeCache(in: directory, now: now.addingTimeInterval(-60))
        let futureSnapshot = try await future.load()
        XCTAssertNil(futureSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMalformedJSONIsClearedAndReturnsNil() async throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("account-v1.json")
        try Data("not-json".utf8).write(to: file)
        let cache = makeCache(in: directory, now: now)

        let loaded = try await cache.load()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnknownSchemaIsClearedAndReturnsNil() async throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("account-v1.json")
        let data = try JSONEncoder().encode(AccountSnapshot(version: 99, account: account(), guilds: [guild()], savedAt: now))
        try data.write(to: file)
        let cache = makeCache(in: directory, now: now)

        let loaded = try await cache.load()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSaveUsesPrivateDirectoryAndFilePermissions() async throws {
        let directory = try makeDirectory()
        let cache = makeCache(in: directory, now: now)

        try await cache.save(account: account(), guilds: [guild()])

        let file = directory.appendingPathComponent("account-v1.json")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
