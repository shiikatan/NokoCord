import SwiftUI

/// Keep an option's explanation beside the control it describes.
struct SettingsControlLabel: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    init(_ title: LocalizedStringKey, explanation: LocalizedStringKey) {
        self.title = title
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.primary)
            Text(explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3).accessibilityElement(children: .combine)
    }
}
