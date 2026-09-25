import SwiftUI

struct DownloadsPopoverView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("Downloads")
                    .font(.headline)
                Spacer()
                if !browser.downloads.records.isEmpty {
                    Text("\(browser.downloads.records.count)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let error = browser.downloads.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { browser.downloads.dismissError() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            if browser.downloads.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No Downloads Yet")
                        .font(.subheadline.weight(.semibold))
                    Text("Files you download from Discord will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(browser.downloads.records) { item in
                            DownloadRowItem(item: item) {
                                browser.downloads.cancel(item.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
        .nokoCordAppearance()
    }
}

private struct DownloadRowItem: View {
    let item: BrowserDownloadRecord
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                
                switch item.status {
                case .choosing:
                    Text("Choosing destination…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .downloading:
                    ProgressView(value: item.fraction)
                        .controlSize(.small)
                case .complete:
                    Text("Completed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 4)

            if item.status == .choosing || item.status == .downloading {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var statusIcon: String {
        switch item.status {
        case .choosing, .downloading: "arrow.down.circle"
        case .complete: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .choosing, .downloading: .accentColor
        case .complete: .green
        case .cancelled: .secondary
        case .failed: .red
        }
    }
}
