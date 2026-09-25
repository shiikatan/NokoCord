import SwiftUI
import AppKit

// MARK: - Fluid Spring Animations & Motion Tokens
extension Animation {
    /// Apple-standard fluid spring for panels, sheets, and interactive overlays.
    static var nokoFluidSpring: Animation {
        .spring(response: 0.36, dampingFraction: 0.82)
    }

    /// Snappy micro-animation for button clicks, toggles, and state changes.
    static var nokoSnappySpring: Animation {
        .spring(response: 0.24, dampingFraction: 0.78)
    }

    /// Gentle ease for subtle fades and backdrop transitions.
    static var nokoGentleEase: Animation {
        .easeInOut(duration: 0.22)
    }
}

// MARK: - Liquid Glass & Surface Modifiers
struct NokoGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var isHovered: Bool = false
    var isSelected: Bool = false
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let borderColor = isSelected
            ? Color.accentColor.opacity(0.8)
            : (isHovered
                ? Color.primary.opacity(contrast == .increased ? 0.6 : (colorScheme == .dark ? 0.24 : 0.18))
                : Color.primary.opacity(contrast == .increased ? 0.4 : (colorScheme == .dark ? 0.12 : 0.08)))

        let borderWidth: CGFloat = isSelected ? 1.5 : (contrast == .increased ? 1.5 : 1.0)

        if !useLiquidGlass || reduceTransparency || contrast == .increased {
            content
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(isHovered ? 1.0 : 0.85),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    borderColor,
                                    borderColor.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: borderWidth
                        )
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.35 : 0.2) : (isHovered ? 0.12 : 0.05)),
                    radius: isHovered ? 14 : 8,
                    x: 0,
                    y: isHovered ? 6 : 3
                )
        }
    }
}

// MARK: - Interactive Button & Pill Styles
struct NokoPillBadge: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct NokoStatusDot: View {
    var color: Color = .green
    var pulse: Bool = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if pulse {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isPulsing ? 1.4 : 0.9)
                    .opacity(isPulsing ? 0 : 0.8)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: isPulsing)
                    .onAppear { isPulsing = true }
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - View Extension Helpers
extension View {
    func nokoGlassCard(cornerRadius: CGFloat = 16, isHovered: Bool = false, isSelected: Bool = false) -> some View {
        modifier(NokoGlassCard(cornerRadius: cornerRadius, isHovered: isHovered, isSelected: isSelected))
    }
}
