import SwiftUI

/// A compact, user-facing explanation of which Discord surfaces are verified.
/// It deliberately renders only native, sanitized diagnostics from the probe
/// reducer; page text and selectors never reach this view.
struct CompatibilityCenterView: View {
    let snapshot: DiscordCompatibilitySnapshot
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                featureList
                if !fallbacks.isEmpty {
                    fallbackSection
                }
                explanation
                if let onRefresh {
                    Button("Check again", systemImage: "arrow.clockwise", action: onRefresh)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 440, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .font(.title2)
                .foregroundStyle(headerColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Compatibility Center")
                    .font(.title3.weight(.semibold))
                Text(routeTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verified Discord surfaces")
                .font(.headline)
            ForEach(DiscordFeature.allCases, id: \.self) { feature in
                let diagnostic = snapshot.diagnostic(for: feature)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: snapshot.state(for: feature)))
                        .foregroundStyle(color(for: snapshot.state(for: feature)))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: feature))
                            .font(.callout.weight(.medium))
                        Text(diagnostic?.sanitizedMessage ?? "Compatibility has not been checked yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let diagnostic, diagnostic.checkedAnchorCount + diagnostic.checkedCapabilityCount > 0 {
                            Text("Checked \(diagnostic.checkedAnchorCount) anchors and \(diagnostic.checkedCapabilityCount) capabilities")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reduced-compatibility warnings")
                .font(.headline)
            ForEach(fallbacks, id: \.id) { fallback in
                Label(fallback.warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("NokoCord keeps this feature available with a reviewed fallback. If behavior looks wrong, disable the affected integration and report the Discord surface change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var explanation: some View {
        Text("NokoCord checks only bounded DOM presence, element types, and browser capabilities. It does not copy messages, account identifiers, cookies, or page text into native diagnostics. Unsupported surfaces fail open and remain ordinary Discord pages.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var fallbacks: [DiscordSelectorFallbackMetadata] {
        DiscordFeature.allCases.flatMap { snapshot.diagnostic(for: $0)?.matchedFallbacks ?? [] }
    }

    private var routeTitle: String {
        switch snapshot.route {
        case "app": "Discord application"
        case "channels": "Discord channel workspace"
        case "fixture": "Compatibility fixture"
        case "unknown": "Waiting for a supported Discord surface"
        default: "Protected Discord surface"
        }
    }

    private var lastCheckedText: String {
        guard let date = snapshot.lastProbeAt else { return "Not checked in this document" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var headerIcon: String {
        if snapshot.features.values.contains(.unsupported) { return "shield.lefthalf.filled" }
        if snapshot.features.values.contains(.degraded) { return "exclamationmark.shield.fill" }
        if snapshot.features.values.allSatisfy({ $0 == .healthy }) { return "checkmark.shield.fill" }
        return "questionmark.shield.fill"
    }

    private var headerColor: Color {
        if snapshot.features.values.contains(.unsupported) { return .red }
        if snapshot.features.values.contains(.degraded) { return .orange }
        if snapshot.features.values.allSatisfy({ $0 == .healthy }) { return .green }
        return .secondary
    }

    private func title(for feature: DiscordFeature) -> String {
        switch feature {
        case .navigation: "Navigation"
        case .messages: "Messages"
        case .composer: "Message composer"
        case .media: "Attachments and media"
        case .calls: "Calls"
        case .notifications: "Notifications"
        case .activity: "Local activity"
        }
    }

    private func icon(for state: DiscordFeatureState) -> String {
        switch state {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .unsupported: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(for state: DiscordFeatureState) -> Color {
        switch state {
        case .healthy: .green
        case .degraded: .orange
        case .unsupported: .red
        case .unknown: .secondary
        }
    }
}
