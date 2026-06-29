import SwiftUI
import StratusCore

struct UploadCenterView: View {
    @EnvironmentObject private var env: AppEnvironment

    private var inProgressRows: [UploadRowState] {
        env.uploadRows.filter { $0.phase == .hashing || $0.phase == .uploading }
    }

    private var queuedRows: [UploadRowState] {
        env.uploadRows.filter { $0.phase == .queued }
    }

    private var pausedRows: [UploadRowState] {
        env.uploadRows.filter { $0.phase == .paused }
    }

    private var failedRows: [UploadRowState] {
        env.uploadRows.filter { $0.phase == .failed }
    }

    private var completedRows: [UploadRowState] {
        env.uploadRows.filter { $0.phase == .completed }
    }

    var body: some View {
        VStack(spacing: 0) {
            UploadSummaryCard(summary: env.uploadSummary)
                .padding(Spacing.lg)
                .background(Color.surfacePrimary)
            Divider()

            if env.uploadRows.isEmpty {
                DropZoneEmptyState()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        UploadSection(title: "In Progress", rows: inProgressRows) { row in
                            UploadItemRowView(row: row, primaryAction: .pause)
                        }
                        UploadSection(title: "Queued", rows: queuedRows) { row in
                            UploadItemRowView(row: row, primaryAction: .prioritize)
                        }
                        UploadSection(title: "Paused", rows: pausedRows) { row in
                            UploadItemRowView(row: row, primaryAction: .resume)
                        }
                        UploadSection(title: "Failed", rows: failedRows) { row in
                            UploadItemRowView(row: row, primaryAction: .retry)
                        }
                        UploadSection(title: "Completed", rows: completedRows) { row in
                            UploadItemRowView(row: row, primaryAction: .none)
                        }
                    }
                    .padding(Spacing.lg)
                }
                .background(Color.surfaceSecondary)
            }
        }
        .navigationTitle("Upload Center")
        .toolbar {
            ToolbarItemGroup {
                Button("Pause All") {
                    Task { await env.uploadEngine.pauseAll() }
                }
                .disabled(env.uploadSummary.activeCount == 0)

                Button("Resume All") {
                    Task { await env.uploadEngine.resumeAll() }
                }
                .disabled(env.uploadSummary.pausedCount == 0 && env.uploadSummary.queuedCount == 0)

                Button("Cancel All", role: .destructive) {
                    Task { await env.uploadEngine.cancelAll() }
                }
                .disabled(env.uploadRows.isEmpty)
            }
        }
    }
}

// MARK: - Summary Card

private struct UploadSummaryCard: View {
    let summary: UploadDashboardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
                StatCell(label: "Current", value: formatSpeed(summary.currentBPS))
                StatCell(label: "Peak", value: formatSpeed(summary.peakBPS))
                StatCell(label: "Files", value: "\(summary.activeCount) active · \(summary.queuedCount) queued")
                StatCell(label: "ETA", value: formatETA(summary.etaSeconds))
                Spacer(minLength: Spacing.lg)
                SpeedGraph(samples: [summary.currentBPS, summary.peakBPS, summary.currentBPS])
                    .frame(width: 180, height: 40)
                    .accessibilityLabel("Upload speed graph")
            }

            HStack(spacing: Spacing.md) {
                ProgressView(value: summary.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Overall upload progress")
                    .accessibilityValue("\(Int(summary.progress * 100)) percent")
                Text("\(Int(summary.progress * 100))%")
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text("\(formatBytes(summary.bytesTransferred)) of \(formatBytes(summary.totalBytes)) · \(summary.failedCount) failed · \(summary.pausedCount) paused · \(summary.completedCount) completed")
                .stratusCaption()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatCell: View {
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

// MARK: - Sections

private struct UploadSection<Content: View>: View {
    let title: String
    let rows: [UploadRowState]
    @ViewBuilder let content: (UploadRowState) -> Content

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
                        content(row)
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

// MARK: - Upload Row

private struct UploadItemRowView: View {
    enum PrimaryAction {
        case pause
        case resume
        case retry
        case prioritize
        case none
    }

    @EnvironmentObject private var env: AppEnvironment
    let row: UploadRowState
    let primaryAction: PrimaryAction

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ProviderIcon(providerID: row.providerID, size: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(row.fileName)
                        .font(.stratusBody.weight(.medium))
                        .lineLimit(1)
                    StatusBadge(status: statusBadge)
                    Text(phaseLabel)
                        .stratusCaption()
                }

                ProgressView(value: row.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("\(row.fileName) progress")
                    .accessibilityValue("\(Int(row.progress * 100)) percent")

                Text(detailLine)
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.md)

            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(formatSpeed(row.speedBPS))
                    .font(.stratusSmallMono)
                    .foregroundColor(.textPrimary)
                Text(formatETA(row.etaSeconds))
                    .stratusCaption()
                actionButton
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        let bytes = "\(formatBytes(row.bytesTransferred)) / \(formatBytes(row.totalBytes))"
        let chunk = row.chunkText.map { " · \($0)" } ?? ""
        return "\(bytes) · \(row.destinationPath)\(chunk) · \(row.detailText)"
    }

    private var phaseLabel: String {
        switch row.phase {
        case .queued: return "Queued"
        case .hashing: return "Preparing"
        case .uploading: return "\(Int(row.progress * 100))%"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .completed: return row.checksumVerified ? "Verified" : "Done"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }

    private var statusBadge: StatusBadge.Status {
        switch row.phase {
        case .hashing, .uploading: return .active
        case .paused: return .paused
        case .failed: return .failed
        default: return .idle
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch primaryAction {
        case .pause:
            Button("Pause") { Task { await env.uploadEngine.pause(taskID: row.id) } }
                .buttonStyle(.borderless)
        case .resume:
            Button("Resume") { Task { await env.uploadEngine.resume(taskID: row.id) } }
                .buttonStyle(.borderless)
        case .retry:
            Button("Retry") { Task { await env.uploadEngine.resume(taskID: row.id) } }
                .buttonStyle(.borderless)
        case .prioritize:
            Button("Prioritize") { }
                .buttonStyle(.borderless)
                .disabled(true)
                .help("Priority changes are handled by the scheduler; selection support is next.")
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Empty State

private struct DropZoneEmptyState: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.textTertiary)
            VStack(spacing: Spacing.xs) {
                Text("No upload activity")
                    .font(.stratusHeadline)
                Text("Start an upload from the file browser. Every file will show bytes, speed, chunk progress, checksum status, and retry state here.")
                    .font(.stratusBody)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceSecondary)
    }
}

// MARK: - Formatting

private func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func formatSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "0 B/s" }
    return "\(formatBytes(Int64(bps)))/s"
}

private func formatETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds) % 60)s" }
    return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600)) / 60)m"
}
