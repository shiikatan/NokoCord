import Foundation

/// Shared first-launch values for settings that are read by both SwiftUI and
/// the application bootstrap path. Registering these values keeps an absent
/// preference distinct from an explicitly disabled preference.
enum NokoAppDefaults {
    static let showMenuBar = "showMenuBar"
    static let openDiscordOnLaunch = "openDiscordOnLaunch"
    static let useLiquidGlass = "useLiquidGlass"
    static let appearance = "appearance"
    static let hasSeenWelcomeTutorial = "hasSeenWelcomeTutorial"
    static let showFloatingToolbar = "showFloatingToolbar"
    static let hideNokoTans = "hideNokoTans"

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showMenuBar: true,
            openDiscordOnLaunch: true,
            useLiquidGlass: true,
            appearance: "system",
            hasSeenWelcomeTutorial: false,
            showFloatingToolbar: false,
            hideNokoTans: false
        ])
    }
}
