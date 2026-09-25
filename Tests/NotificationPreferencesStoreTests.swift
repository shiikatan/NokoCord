import Foundation
import XCTest
@testable import NokoCordCore

final class NotificationPreferencesStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NokoCord.NotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testMissingValueLoadsSafeDefaults() {
        let defaults = makeDefaults()
        let store = NotificationPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), NotificationPreferences())
    }

    func testSaveAndLoadRoundTrip() throws {
        let defaults = makeDefaults()
        let store = NotificationPreferencesStore(defaults: defaults)
        var expected = NotificationPreferences()
        expected.enabled[.mention] = false
        expected.enabled[.incomingCall] = false
        expected.showPreviews = true

        try store.save(expected)

        XCTAssertEqual(store.load(), expected)
        XCTAssertNotNil(defaults.data(forKey: NotificationPreferencesStore.storageKey))
    }

    func testMalformedDataLoadsSafeDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: NotificationPreferencesStore.storageKey)
        let store = NotificationPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), NotificationPreferences())
    }

    func testUnknownVersionLoadsSafeDefaults() throws {
        let defaults = makeDefaults()
        let store = NotificationPreferencesStore(defaults: defaults)
        var expected = NotificationPreferences()
        expected.showPreviews = true
        try store.save(expected)

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: NotificationPreferencesStore.storageKey))
        ) as? [String: Any])
        envelope["version"] = NotificationPreferencesStore.currentVersion + 1
        defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: NotificationPreferencesStore.storageKey)

        XCTAssertEqual(store.load(), NotificationPreferences())
    }

    func testOversizedDataLoadsSafeDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data(repeating: 0x01, count: NotificationPreferencesStore.maximumEncodedBytes + 1), forKey: NotificationPreferencesStore.storageKey)
        let store = NotificationPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), NotificationPreferences())
    }
}
