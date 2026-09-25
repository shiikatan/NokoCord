import SwiftUI
import AppKit

/// Interactive first-launch welcome tutorial showcasing NokoCord's native macOS features,
/// command palette, game rich presence, and shortcuts in an Apple Liquid Glass modal.
struct WelcomeTutorialView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasSeenWelcomeTutorial") private var hasSeenWelcomeTutorial = false
    @State private var currentStep = 0
    @State private var isHoveringClose = false
    @State private var isHoveringNext = false

    private let totalSteps = 4

    var body: some View {
        ZStack {
            // Backdrop dimming
            Color.black.opacity(0.45)
                .background(.ultraThinMaterial.opacity(0.4))
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Main Liquid Glass Card
            VStack(spacing: 0) {
                // Header Bar with Window Traffic Close Button & Page Indicator
                HStack {
                    // Step Dots Indicator
                    HStack(spacing: 6) {
                        ForEach(0..<totalSteps, id: \.self) { step in
                            Capsule()
                                .fill(currentStep == step ? Color.accentColor : Color.white.opacity(0.2))
                                .frame(width: currentStep == step ? 22 : 6, height: 6)
                                .animation(.nokoSnappySpring, value: currentStep)
                                .onTapGesture {
                                    withAnimation(.nokoFluidSpring) {
                                        currentStep = step
                                    }
                                }
                        }
                    }

                    Spacer()

                    // Close Button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(isHoveringClose ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringClose = $0 }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 12)

                // Step Content View
                ZStack {
                    switch currentStep {
                    case 0:
                        step0Welcome
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    case 1:
                        step1CommandPalette
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    case 2:
                        step2GamePresenceAudio
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    default:
                        step3ShortcutsAndTips
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    }
                }
                .animation(.nokoFluidSpring, value: currentStep)
                .frame(height: 380)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                // Footer Navigation Bar
                HStack {
                    if currentStep > 0 {
                        Button {
                            withAnimation(.nokoFluidSpring) {
                                currentStep -= 1
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.caption.weight(.bold))
                                Text("Back")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button("Skip Tour") {
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    }

                    Spacer()

                    Button {
                        if currentStep < totalSteps - 1 {
                            withAnimation(.nokoFluidSpring) {
                                currentStep += 1
                            }
                        } else {
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentStep == totalSteps - 1 ? "Get Started" : "Continue")
                                .font(.callout.weight(.semibold))
                            Image(systemName: currentStep == totalSteps - 1 ? "sparkles" : "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(isHoveringNext ? 1.02 : 1.0)
                    .onHover { isHoveringNext = $0 }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.22))
            }
            .frame(width: 580)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.55), radius: 36, y: 16)
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.94).combined(with: .opacity),
            removal: .scale(scale: 0.97).combined(with: .opacity)
        ))
    }

    private func dismiss() {
        hasSeenWelcomeTutorial = true
        withAnimation(.nokoFluidSpring) {
            isPresented = false
        }
    }

    // MARK: - Step 0: Welcome & The Native Advantage
    private var step0Welcome: some View {
        VStack(spacing: 20) {
            // Icon & Badge
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)

                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.accentColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text("Welcome to NokoCord")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("The ultra-fast, native macOS client for Discord")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                featureRow(
                    icon: "bolt.fill",
                    tint: .yellow,
                    title: "Instant Startup & Zero Electron Bloat",
                    description: "Powered by native macOS WebKit with 120Hz ProMotion smoothness and true battery efficiency."
                )

                featureRow(
                    icon: "lock.shield.fill",
                    tint: .green,
                    title: "Private & Sandboxed",
                    description: "Runs within Apple App Sandbox. Discord owns authentication; your login tokens are never touched."
                )

                featureRow(
                    icon: "macwindow.on.rectangle",
                    tint: .blue,
                    title: "Zero UI Clutter",
                    description: "No permanent floating badges or injected buttons. 100% full-screen Discord viewport."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    // MARK: - Step 1: The Quick Selector (⌘K)
    private var step1CommandPalette: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.25))
                    .frame(width: 70, height: 70)

                Image(systemName: "command")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.blue)
            }
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text("Your Single Hub: Quick Selector")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text("Press")
                    Text("⌘K")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    Text("anywhere, anytime")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                featureRow(
                    icon: "magnifyingglass",
                    tint: .blue,
                    title: "Instant Spotlight Search",
                    description: "Jump between Discord channels, preferences, extensions, or run commands in one keystroke."
                )

                featureRow(
                    icon: "arrow.up.left.and.arrow.down.right",
                    tint: .cyan,
                    title: "Persistent Zoom Scaling",
                    description: "Scale Discord with ⌘+ and ⌘-. Your custom zoom level is remembered across app restarts."
                )

                featureRow(
                    icon: "sparkles",
                    tint: .purple,
                    title: "Tans & Themes Management",
                    description: "Inspect active client extensions, toggle safe mode, or reload without touching the web page."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    // MARK: - Step 2: Game Rich Presence & Voice Call HUD
    private var step2GamePresenceAudio: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.25))
                    .frame(width: 70, height: 70)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text("Game Rich Presence & Native Audio")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Engineered exclusively for macOS gaming and voice")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                featureRow(
                    icon: "gamecontroller",
                    tint: .purple,
                    title: "Native Game Presence (Discord IPC)",
                    description: "Local IPC listening on /tmp/discord-ipc-0. Games automatically broadcast status to your Discord friends."
                )

                featureRow(
                    icon: "phone.bubble.fill",
                    tint: .green,
                    title: "Apple Liquid Glass Voice HUD",
                    description: "Floating indicator reveals during active calls. Mute hardware mic with ⌘⇧M or disconnect with ⌘⇧D."
                )

                featureRow(
                    icon: "bell.badge.fill",
                    tint: .orange,
                    title: "macOS Notification Banners",
                    description: "Discord mentions and DMs appear natively in macOS Notification Center with sound and badges."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    // MARK: - Step 3: Shortcuts & Navigation
    private var step3ShortcutsAndTips: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 66, height: 66)

                Image(systemName: "keyboard.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 6)

            VStack(spacing: 4) {
                Text("Essential Shortcuts & Tips")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Everything you need for effortless Discord power-use")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Shortcuts Grid
            VStack(spacing: 8) {
                shortcutRow(keys: ["⌘", "K"], label: "Quick Selector Hub", detail: "Universal spotlight for all controls")
                shortcutRow(keys: ["⌘", "T"], label: "Tans Inspector", detail: "Slide out extension drawer")
                shortcutRow(keys: ["⌘", "1"], label: "Jump to Discord", detail: "Return to active channels")
                shortcutRow(keys: ["⌘", "+", "/ -"], label: "Zoom In / Out", detail: "Smooth, persistent UI scaling")
                shortcutRow(keys: ["⌘", "⇧", "M"], label: "Toggle Mute", detail: "Instantly silence microphone in calls")
            }
            .padding(.horizontal, 28)

            // Pro Tip Capsule
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                Text("Tip: Drag the window from any empty background space, or hover the top-right corner to reveal the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    // MARK: - Helper Subviews
    private func featureRow(icon: String, tint: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func shortcutRow(keys: [String], label: String, detail: String) -> some View {
        HStack {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(width: 76, alignment: .leading)

            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
