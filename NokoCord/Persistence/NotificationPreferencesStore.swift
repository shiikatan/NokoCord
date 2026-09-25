import Foundation

enum NotificationPreferencesStoreError: Error, Equatable {
    case encodedDataTooLarge
}

struct NotificationPreferencesStore {
    static let storageKey = "notificationPreferences.v1"
    static let currentVersion = 1
    static let maximumEncodedBytes = 16 * 1024

    private struct Envelope: Codable, Sendable {
        let version: Int
        let preferences: NotificationPreferences
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NotificationPreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              data.count <= Self.maximumEncodedBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            return NotificationPreferences()
        }
        return envelope.preferences
    }

    func save(_ preferences: NotificationPreferences) throws {
        let envelope = Envelope(version: Self.currentVersion, preferences: preferences)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maximumEncodedBytes else {
            throw NotificationPreferencesStoreError.encodedDataTooLarge
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
