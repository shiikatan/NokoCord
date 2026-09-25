import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class NotificationSettings {
    private(set) var preferences: NotificationPreferences
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var checkingPermission = false
    private(set) var errorMessage: String?
    @ObservationIgnored let service: NotificationService
    @ObservationIgnored private let persistence: NotificationPreferencesStore

    init(persistence: NotificationPreferencesStore = .init(), service: NotificationService? = nil) {
        self.persistence = persistence
        let saved = persistence.load()
        preferences = saved
        self.service = service ?? NotificationService(preferences: saved)
        self.service.updatePreferences(saved)
    }

    func setEnabled(_ enabled: Bool, for type: NotificationEventType) {
        var updated = preferences
        updated.enabled[type] = enabled
        save(updated)
    }

    func setPreviews(_ enabled: Bool) {
        var updated = preferences
        updated.showPreviews = enabled
        save(updated)
    }

    private func save(_ updated: NotificationPreferences) {
        do {
            try persistence.save(updated)
            preferences = updated
            service.updatePreferences(updated)
            // Previously posted previews should not outlive a privacy preference change.
            service.clearOnLogout()
            errorMessage = nil
        } catch { errorMessage = String(localized: "Notification preferences could not be saved. Try again.") }
    }

    func refreshAuthorization() async { authorization = await service.authorizationStatus() }

    func requestAuthorization() async {
        guard !checkingPermission else { return }
        checkingPermission = true
        defer { checkingPermission = false }
        do {
            _ = try await service.requestAuthorization()
            errorMessage = nil
        } catch { errorMessage = String(localized: "Notification permission could not be requested. Try again.") }
        await refreshAuthorization()
    }
}
