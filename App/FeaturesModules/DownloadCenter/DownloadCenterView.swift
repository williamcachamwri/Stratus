import StratusCore
import SwiftUI

public struct DownloadCenterView: View {
    @EnvironmentObject private var env: AppEnvironment

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DownloadSummaryCard(summary: env.downloadSummary)
                .padding(Spacing.lg)
                .background(Color.surfacePrimary)
            Divider()

            if env.downloadRows.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.doc",
                    title: "No download activity",
                    subtitle: "Real download events from DownloadEngine will appear here with bytes, range segments, speed, ETA, and resume state."
                )
                .background(Color.surfaceSecondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        DownloadSection(title: "In Progress", rows: rows(.downloading))
                        DownloadSection(title: "Queued", rows: rows(.queued) + rows(.restored))
                        DownloadSection(title: "Paused", rows: rows(.paused))
                        DownloadSection(title: "Failed", rows: rows(.failed))
                        DownloadSection(title: "Completed", rows: rows(.completed))
                    }
                    .padding(Spacing.lg)
                }
                .background(Color.surfaceSecondary)
            }
        }
        .navigationTitle("Download Center")
        .toolbar {
            ToolbarItemGroup {
                Button("Pause All") {
                    Task { await env.downloadEngine.pauseAll() }
                }
                .disabled(env.downloadSummary.activeCount == 0)

                Button("Resume All") {
                    Task { await env.downloadEngine.resumeAll() }
                }
                .disabled(env.downloadSummary.pausedCount == 0)

                Button("Cancel All", role: .destructive) {
                    Task { await env.downloadEngine.cancelAll() }
                }
                .disabled(env.downloadRows.isEmpty)
            }
        }
    }

    private func rows(_ phase: DownloadDisplayPhase) -> [DownloadRowState] {
        env.downloadRows.filter { $0.phase == phase }
    }
}

private struct DownloadSummaryCard: View {
    let summary: DownloadDashboardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
                DownloadStatCell(label: "Current", value: formatTransferSpeed(summary.currentBPS))
                DownloadStatCell(label: "Files", value: "\(summary.activeCount) active · \(summary.queuedCount) queued")
                DownloadStatCell(label: "ETA", value: formatTransferETA(summary.etaSeconds))
                Spacer()
            }

            HStack(spacing: Spacing.md) {
                ProgressView(value: summary.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Overall download progress")
                    .accessibilityValue("\(Int(summary.progress * 100)) percent")
                Text("\(Int(summary.progress * 100))%")
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text(
                "\(formatTransferBytes(summary.bytesReceived)) of \(formatTransferBytes(summary.totalBytes)) · \(summary.failedCount) failed · \(summary.pausedCount) paused · \(summary.completedCount) completed"
            )
            .stratusCaption()
        }
    }
}

private struct DownloadStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(.stratusSmallMono)
                .foregroundColor(.textPrimary)
        }
    }
}

private struct DownloadSection: View {
    let title: String
    let rows: [DownloadRowState]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("\(title) (\(rows.count))")
                        .font(.stratusHeadline)
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        DownloadItemRow(row: row)
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(Color.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            }
        }
    }
}

private struct DownloadItemRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let row: DownloadRowState

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ProviderIcon(providerID: row.providerID, size: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(row.fileName)
                        .font(.stratusBody.weight(.medium))
                        .lineLimit(1)
                    Text(phaseLabel)
                        .stratusCaption()
                }
                ProgressView(value: row.progress)
                    .accessibilityLabel("\(row.fileName) download progress")
                    .accessibilityValue("\(Int(row.progress * 100)) percent")
                Text(
                    "\(formatTransferBytes(row.bytesReceived)) / \(formatTransferBytes(row.totalBytes)) · \(row.sourcePath) · \(row.rangeText) · \(row.detailText)"
                )
                .font(.stratusSmallMono)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: Spacing.md)

            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(formatTransferSpeed(row.speedBPS))
                    .font(.stratusSmallMono)
                Text(formatTransferETA(row.etaSeconds))
                    .stratusCaption()
                actionButton
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var phaseLabel: String {
        switch row.phase {
        case .queued, .restored: "Queued"
        case .downloading: "\(Int(row.progress * 100))%"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: row.checksumVerified ? "Verified" : "Done"
        case .cancelled: "Cancelled"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch row.phase {
        case .downloading:
            Button("Pause") { Task { await env.downloadEngine.pause(taskID: row.id) } }
                .buttonStyle(.borderless)
        case .paused:
            Button("Resume") { Task { await env.downloadEngine.resume(taskID: row.id) } }
                .buttonStyle(.borderless)
        case .failed:
            Button("Retry") { Task { await env.downloadEngine.resume(taskID: row.id) } }
                .buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }
}

private func formatTransferBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func formatTransferSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "0 B/s" }
    return "\(formatTransferBytes(Int64(bps)))/s"
}

private func formatTransferETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
}
