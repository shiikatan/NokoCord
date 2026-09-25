import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(NotificationSettings.self) private var settings
    var body: some View {
        Form {
            Section("Notifications") {
                Text("Notification delivery is unavailable with the current Discord connection. Preferences are saved for supported events when an authorized connection becomes available.")
                    .foregroundStyle(.secondary)
                LabeledContent("System permission", value: permissionTitle)
                Button("Allow notifications…") { Task { await settings.requestAuthorization() } }
                    .disabled(settings.checkingPermission || settings.authorization != .notDetermined)
                if settings.authorization == .denied {
                    Text("You can change notification permission in macOS System Settings → Notifications → NokoCord.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = settings.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("Event preferences") {
                ForEach(NotificationEventType.allCases, id: \.self) { type in
                    Toggle(type.settingsTitle, isOn: Binding(
                        get: { settings.preferences.enabled[type, default: true] },
                        set: { settings.setEnabled($0, for: type) }))
                }
            }
            Section("Privacy") {
                Toggle("Show names and message previews", isOn: Binding(
                    get: { settings.preferences.showPreviews }, set: { settings.setPreviews($0) }))
                Text("Previews are hidden by default. Changing preferences clears existing NokoCord notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await settings.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await settings.refreshAuthorization() }
        }
    }
    private var permissionTitle: String {
        switch settings.authorization {
        case .notDetermined: String(localized: "Not requested")
        case .denied: String(localized: "Denied")
        case .authorized: String(localized: "Allowed")
        case .provisional: String(localized: "Quiet delivery")
        case .ephemeral: String(localized: "Temporary")
        @unknown default: String(localized: "Unknown")
        }
    }
}

private extension NotificationEventType {
    var settingsTitle: String {
        switch self {
        case .directMessage: String(localized: "Direct messages")
        case .mention: String(localized: "Mentions")
        case .reply: String(localized: "Replies")
        case .thread: String(localized: "Thread activity")
        case .incomingCall: String(localized: "Incoming calls")
        case .friendRequest: String(localized: "Friend requests")
        }
    }
}
