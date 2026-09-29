import SwiftUI

/// A shared, redacted identity diff shown before a changed Tan is approved.
/// Full content hashes are never rendered; the trust ledger remains the
/// authority for the actual comparison.
struct TanTrustDiffView: View {
    let diff: TanTrustDiff

    init(package: TanPackage, record: TanTrustRecord?) {
        self.diff = TanTrustDiff.make(package: package, record: record)
    }

    init(diff: TanTrustDiff) {
        self.diff = diff
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: diff.requiresApproval ? "arrow.triangle.2.circlepath" : "checkmark.shield")
                    .foregroundStyle(diff.requiresApproval ? .orange : .green)
                Text(diff.requiresApproval ? "Trust changed — review before approval" : "Trust identity unchanged")
                    .font(.subheadline.weight(.semibold))
            }

            if diff.items.isEmpty {
                Text("The package hash, target, capabilities, and trust origin match the recorded identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diff.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.field.title)
                                .font(.caption.weight(.semibold))
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.previousValue)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(item.currentValue)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            .font(.caption.monospaced())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.field.title): \(item.previousValue) changed to \(item.currentValue)")
                    }
                }
            }
        }
        .padding(12)
        .background((diff.requiresApproval ? Color.orange : Color.green).opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder((diff.requiresApproval ? Color.orange : Color.green).opacity(0.22))
        )
    }
}
