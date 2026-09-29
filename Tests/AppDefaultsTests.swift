import XCTest
@testable import NokoCordCore

final class AppDefaultsTests: XCTestCase {
    func testRegisterProvidesTheSameFirstLaunchValuesUsedByTheShellAndSettings() {
        let suite = "NokoCord.AppDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        NokoAppDefaults.register(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: NokoAppDefaults.openDiscordOnLaunch))
        XCTAssertTrue(defaults.bool(forKey: NokoAppDefaults.showMenuBar))
        XCTAssertTrue(defaults.bool(forKey: NokoAppDefaults.useLiquidGlass))
        XCTAssertEqual(defaults.string(forKey: NokoAppDefaults.appearance), "system")
        XCTAssertFalse(defaults.bool(forKey: NokoAppDefaults.hasSeenWelcomeTutorial))
    }
}
