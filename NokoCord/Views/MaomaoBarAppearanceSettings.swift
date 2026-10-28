import SwiftUI

struct MaomaoBarAppearanceSettings: View {
    @AppStorage(MaomaoWorkspaceAppearance.barPreferenceKey) private var enabled = true
    @State private var confirmHide = false

    var body: some View {
        Toggle(isOn: Binding(
            get: { enabled },
            set: { value in
                if value { enabled = true }
                else { confirmHide = true }
            }
        )) {
            SettingsControlLabel("Show Noko-Bar", explanation: "Show navigation and controls above Discord. Restore it anytime with ⌃⌘N.")
        }
        .alert("Hide Noko-Bar?", isPresented: $confirmHide) {
            Button("Cancel", role: .cancel) {}
            Button("Hide Noko-Bar") { enabled = false }
        } message: {
            Text("Press Control–Command–N (⌃⌘N) to show Noko-Bar again. You can also turn it back on in Settings → Discord.")
        }
    }
}
