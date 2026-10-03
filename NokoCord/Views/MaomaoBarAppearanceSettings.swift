import SwiftUI

struct MaomaoBarAppearanceSettings: View {
    @AppStorage(MaomaoWorkspaceAppearance.barPreferenceKey) private var enabled = true
    @State private var confirmHide = false

    var body: some View {
        Toggle("Noko-Bar", isOn: Binding(
            get: { enabled },
            set: { value in
                if value { enabled = true }
                else { confirmHide = true }
            }
        ))
        .alert("Hide Noko-Bar?", isPresented: $confirmHide) {
            Button("Cancel", role: .cancel) {}
            Button("Hide Noko-Bar") { enabled = false }
        } message: {
            Text("Press Control–Command–N (⌃⌘N) to show Noko-Bar again. You can also turn it back on in Appearance settings.")
        }
        Text("Show the navigation and controls above Discord. Restore anytime with ⌃⌘N.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
