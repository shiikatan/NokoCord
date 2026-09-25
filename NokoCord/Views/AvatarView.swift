import SwiftUI

struct AvatarView: View {
    let url: URL?
    let initials: String
    var size: CGFloat = 32
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Text(initials.isEmpty ? "?" : String(initials.prefix(2))).font(.system(size: size * 0.35, weight: .semibold)).foregroundStyle(.tint).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.12)) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.27))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            if let url { let loaded = await AvatarPipeline.shared.image(for: url); if !Task.isCancelled { image = loaded } }
        }
    }
}
