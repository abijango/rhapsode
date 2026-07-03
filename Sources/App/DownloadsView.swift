import SwiftData
import SwiftUI

/// Visible download queue. Backed by `DownloadItem`; updates live as the
/// `SyncManager` moves items through pending → downloading → done / failed.
struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadItem.remoteEntryID) private var items: [DownloadItem]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Files pulled from Dropbox appear here while they transfer.")
                )
            } else {
                List {
                    ForEach(items) { item in
                        DownloadRow(item: item)
                    }
                    if items.contains(where: { $0.state == .done || $0.state == .failed }) {
                        Button("Clear finished", role: .destructive) { clearFinished() }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clearFinished() {
        for item in items where item.state == .done || item.state == .failed {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    Text(item.kind == .audiobooks ? "Audiobook" : "E-book")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.state == .downloading, let percent = percentText {
                    Text(percent)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.accent)
                }
            }

            if item.state == .pending || item.state == .downloading {
                DownloadProgressBar(fraction: fraction)
                HStack {
                    Text(byteText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if fraction == nil {
                        Text(item.state == .pending ? "Waiting…" : "Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private var name: String {
        if let title = item.title, !title.isEmpty { return title }
        return item.remoteEntryID.split(separator: "/").last.map(String.init) ?? item.remoteEntryID
    }

    /// Completed fraction in 0...1, or `nil` when the total size isn't known yet
    /// (renders as an indeterminate bar rather than a misleading 0%).
    private var fraction: Double? {
        guard item.totalBytes > 0 else { return nil }
        return min(1, max(0, Double(item.bytesReceived) / Double(item.totalBytes)))
    }

    private var percentText: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// "12.3 MB / 27.1 MB" while the total is known, otherwise just the received amount.
    private var byteText: String {
        let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
        guard item.totalBytes > 0 else { return received }
        let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        return "\(received) / \(total)"
    }

    private var icon: some View {
        Group {
            switch item.state {
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
