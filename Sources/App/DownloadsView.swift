import SwiftData
import SwiftUI

/// Visible download queue. Groups MP3-folder children into one row per book,
/// sections active vs failed work, and auto-clears rows once import succeeds.
struct DownloadsView: View {
    @Environment(SyncManager.self) private var sync
    @Query(sort: \DownloadItem.remoteEntryID) private var items: [DownloadItem]

    private var rows: [DownloadQueueRow] { DownloadQueueGrouper.rows(from: items) }
    private var activeRows: [DownloadQueueRow] { DownloadQueueGrouper.active(from: rows) }
    private var failedRows: [DownloadQueueRow] { DownloadQueueGrouper.failed(from: rows) }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Active transfers appear here. Finished books move straight to your library.")
                )
            } else {
                List {
                    if !activeRows.isEmpty {
                        Section("Downloading") {
                            ForEach(activeRows) { row in
                                DownloadRow(row: row)
                            }
                        }
                    }
                    if !failedRows.isEmpty {
                        Section("Failed") {
                            ForEach(failedRows) { row in
                                DownloadRow(row: row, showRetry: true) {
                                    Task { await sync.retryDownload(row) }
                                } onDismiss: {
                                    sync.dismissDownload(row)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DownloadRow: View {
    let row: DownloadQueueRow
    var showRetry = false
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.isActive, let percent = percentText {
                    Text(percent)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.accent)
                }
            }

            if row.isActive {
                DownloadProgressBar(fraction: fraction)
                HStack {
                    Text(byteText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if fraction == nil {
                        Text(row.state == .pending ? "Waiting…" : "Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if showRetry {
                Text("Couldn't finish downloading. Tap Retry — if it keeps failing, disconnect and reconnect Dropbox in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Spacing.md) {
                    Button("Retry", action: { onRetry?() })
                        .buttonStyle(.borderedProminent)
                    if let onDismiss {
                        Button("Dismiss", role: .cancel, action: onDismiss)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private var subtitle: String {
        let kind = row.kind == .audiobooks ? "Audiobook" : "E-book"
        if row.isGroup {
            return "\(kind) · \(row.filesDone) of \(row.filesTotal) files"
        }
        return kind
    }

    private var fraction: Double? {
        guard row.totalBytes > 0 else { return nil }
        return min(1, max(0, Double(row.bytesReceived) / Double(row.totalBytes)))
    }

    private var percentText: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var byteText: String {
        let received = ByteCountFormatter.string(fromByteCount: row.bytesReceived, countStyle: .file)
        guard row.totalBytes > 0 else { return received }
        let total = ByteCountFormatter.string(fromByteCount: row.totalBytes, countStyle: .file)
        return "\(received) / \(total)"
    }

    private var icon: some View {
        Group {
            switch row.state {
            case .pending: Image(systemName: "clock")
            case .downloading: Image(systemName: "arrow.down.circle")
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// A chunky, rounded download progress bar. `fraction == nil` renders an empty
/// track (size not yet known); otherwise the accent fill scales to the row width.
private struct DownloadProgressBar: View {
    let fraction: Double?
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(DS.Palette.accent)
                    .frame(width: (fraction ?? 0) * geo.size.width)
                    .animation(.easeInOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Waiting")
    }
}