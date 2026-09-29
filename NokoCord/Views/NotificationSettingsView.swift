import SwiftUI
import AppKit
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(NotificationSettings.self) private var settings
    var body: some View {
        Form {
            Section("Notifications") {
                Text("NokoCord can show Discord notifications on this Mac. Choose Allow below before Discord can deliver them.")
                    .foregroundStyle(.secondary)
                LabeledContent("System permission", value: permissionTitle)
                Button("Allow notifications…") { Task { await settings.requestAuthorization() } }
                    .disabled(settings.checkingPermission || settings.authorization != .notDetermined)
                if settings.authorization == .denied {
                    Button("Open Notification Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    Text("NokoCord cannot re-open a denied prompt. Turn notifications on in macOS System Settings, then return here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = settings.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("Discord web notifications") {
                Toggle("Deliver notifications from Discord", isOn: Binding(
                    get: { settings.preferences.webNotificationsEnabled },
                    set: { settings.setWebNotifications($0) }
                ))
                Text("NokoCord never asks for notification permission automatically while you browse.")
                    .font(.footnote).foregroundStyle(.secondary)
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
