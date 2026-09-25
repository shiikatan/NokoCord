import XCTest
@testable import NokoCordCore

final class CoreTests: XCTestCase {
    func testPKCEKnownVector() {
        XCTAssertEqual(SecureRandom.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testRandomVerifierHasRequiredEntropyAndAlphabet() throws {
        let a = try SecureRandom.string(), b = try SecureRandom.string()
        XCTAssertEqual(a.count, 43)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }
    func testBrokerRejectsUnsafeOrigins() {
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com/callback", "https://example.com?token=x", "https://example.com#x", "file:///tmp/test", ""] {
            XCTAssertThrowsError(try BrokerConfiguration.origin(value), value)
        }
        XCTAssertNoThrow(try BrokerConfiguration.origin("https://auth.example.com"))
    }
    func testTokensRequireGrantedScopesAndExpiry() throws {
        let invalid = TokenResponse(access_token: "fixture", refresh_token: "fixture", expires_in: 100, token_type: "Bearer", scope: "identify")
        XCTAssertThrowsError(try invalid.credentials(origin: "https://auth.example.com"))
        let valid = TokenResponse(access_token: "fixture", refresh_token: "fixture", expires_in: 100, token_type: "Bearer", scope: "identify guilds")
        let result = try valid.credentials(origin: "https://auth.example.com")
        XCTAssertGreaterThan(result.expiresAt.timeIntervalSinceNow, 95)
        let expired = TokenResponse(access_token: "fixture", refresh_token: "fixture", expires_in: -1, token_type: "Bearer", scope: "identify guilds")
        XCTAssertThrowsError(try expired.credentials(origin: "https://auth.example.com"))
    }
    func testIdentityDecodesOptionalFieldsWithoutInventedData() throws {
        let data = Data(#"{"id":"100","username":"fixture","global_name":null,"avatar":null}"#.utf8)
        let user = try JSONDecoder().decode(DiscordUser.self, from: data)
        XCTAssertEqual(user.displayName, "fixture")
        XCTAssertNil(user.avatar)
        XCTAssertEqual(user, DiscordUser(id: "100", username: "fixture", globalName: nil, avatar: nil))
        XCTAssertNil(user.banner)
        XCTAssertNil(user.accentColor)
        XCTAssertNil(user.publicFlags)
        XCTAssertNil(user.avatarDecorationData)
        XCTAssertNil(user.primaryGuild)
    }
    func testIdentityDecodesProfileMetadataAndPreservesItInCacheEncoding() throws {
        let data = Data(#"""
        {
          "id": "100", "username": "fixture", "global_name": "Fixture User", "avatar": null,
          "banner": "fixture-banner", "accent_color": 16711680, "public_flags": 4194304,
          "avatar_decoration_data": {"asset": "fixture-decoration", "sku_id": "102"},
          "primary_guild": {"identity_guild_id": "101", "identity_enabled": true, "tag": "TEST", "badge": "fixture-badge"}
        }
        """#.utf8)
        let user = try JSONDecoder().decode(DiscordUser.self, from: data)
        XCTAssertEqual(user.displayName, "Fixture User")
        XCTAssertEqual(user.banner, "fixture-banner")
        XCTAssertEqual(user.accentColor, 0xFF0000)
        XCTAssertEqual(user.publicFlags, 1 << 22)
        XCTAssertEqual(user.avatarDecorationData, .init(asset: "fixture-decoration", skuID: "102"))
        XCTAssertEqual(user.primaryGuild, .init(identityGuildID: "101", identityEnabled: true, tag: "TEST", badge: "fixture-badge"))
        let encoded = try JSONEncoder().encode(user)
        XCTAssertEqual(try JSONDecoder().decode(DiscordUser.self, from: encoded), user)
    }
    func testIdentityDistinguishesMissingDisabledAndNullPrimaryGuildMetadata() throws {
        let nullMetadata = Data(#"""
        {"id":"100","username":"fixture","banner":null,"accent_color":null,"public_flags":null,
         "avatar_decoration_data":null,"primary_guild":null}
        """#.utf8)
        let user = try JSONDecoder().decode(DiscordUser.self, from: nullMetadata)
        XCTAssertEqual(user, DiscordUser(id: "100", username: "fixture", globalName: nil, avatar: nil))

        let clearedIdentity = Data(#"""
        {"id":"100","username":"fixture","primary_guild":
         {"identity_guild_id":null,"identity_enabled":null,"tag":null,"badge":null}}
        """#.utf8)
        let cleared = try JSONDecoder().decode(DiscordUser.self, from: clearedIdentity)
        XCTAssertEqual(cleared.primaryGuild, .init(identityGuildID: nil, identityEnabled: nil, tag: nil, badge: nil))

        let disabledIdentity = Data(#"""
        {"id":"100","username":"fixture","primary_guild":
         {"identity_guild_id":"101","identity_enabled":false,"tag":"TEST","badge":"fixture-badge"}}
        """#.utf8)
        let disabled = try JSONDecoder().decode(DiscordUser.self, from: disabledIdentity)
        XCTAssertEqual(disabled.primaryGuild?.identityEnabled, false)
        XCTAssertEqual(disabled.primaryGuild?.tag, "TEST")
    }
    func testGuildPermissionBitsetPreservesFullPrecision() throws {
        let data = Data(#"{"id":"101","name":"Test Guild","permissions":"18446744073709551615"}"#.utf8)
        let guild = try JSONDecoder().decode(DiscordGuild.self, from: data)
        XCTAssertEqual(guild.permissions, "18446744073709551615")
        XCTAssertEqual(guild.initials, "TG")
        XCTAssertEqual(guild, DiscordGuild(id: "101", name: "Test Guild", icon: nil, owner: nil, permissions: "18446744073709551615"))
        XCTAssertNil(guild.approximateMemberCount)
        XCTAssertNil(guild.approximatePresenceCount)
    }
    func testGuildCountMetadataPreservesZeroAndRoundTrips() throws {
        let data = Data(#"""
        {"id":"101","name":"Test Guild","approximate_member_count":128,"approximate_presence_count":0}
        """#.utf8)
        let guild = try JSONDecoder().decode(DiscordGuild.self, from: data)
        XCTAssertEqual(guild.approximateMemberCount, 128)
        XCTAssertEqual(guild.approximatePresenceCount, 0)
        let encoded = try JSONEncoder().encode(guild)
        XCTAssertEqual(try JSONDecoder().decode(DiscordGuild.self, from: encoded), guild)

        let nullCounts = Data(#"""
        {"id":"101","name":"Test Guild","approximate_member_count":null,"approximate_presence_count":null}
        """#.utf8)
        let noCounts = try JSONDecoder().decode(DiscordGuild.self, from: nullCounts)
        XCTAssertNil(noCounts.approximateMemberCount)
        XCTAssertNil(noCounts.approximatePresenceCount)
    }
    @MainActor func testNavigationBranchingAndFiltering() {
        let store = AppStore()
        store.guilds = [.init(id: "1", name: "Alpha", icon: nil, owner: nil, permissions: nil), .init(id: "2", name: "Beta", icon: nil, owner: nil, permissions: nil)]
        store.selectGuild("1"); store.selectGuild("2"); store.goBack()
        XCTAssertEqual(store.selectedGuildID, "1")
        store.selectGuild(nil); store.goForward()
        XCTAssertNil(store.selectedGuildID)
        store.searchText = "ALP"
        XCTAssertEqual(store.filteredGuilds.map(\.id), ["1"])
        XCTAssertNil(store.user)
        XCTAssertEqual(store.state, .signedOut)
    }
}
