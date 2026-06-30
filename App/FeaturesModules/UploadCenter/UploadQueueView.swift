import StratusCore
import SwiftUI

public struct UploadQueueView: View {
    public let rows: [UploadRowState]
    public var onPause: (UUID) -> Void
    public var onResume: (UUID) -> Void
    public var onRetry: (UUID) -> Void
    public var onPrioritize: (UUID) -> Void

    public init(
        rows: [UploadRowState],
        onPause: @escaping (UUID) -> Void = { _ in },
        onResume: @escaping (UUID) -> Void = { _ in },
        onRetry: @escaping (UUID) -> Void = { _ in },
        onPrioritize: @escaping (UUID) -> Void = { _ in }
    ) {
        self.rows = rows
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onPrioritize = onPrioritize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(UploadDisplayPhase.allCases, id: \.self) { phase in
                let phaseRows = rows.filter { $0.phase == phase }
                if !phaseRows.isEmpty {
                    UploadQueueSection(
                        title: title(for: phase),
                        rows: phaseRows,
                        onPause: onPause,
                        onResume: onResume,
                        onRetry: onRetry,
                        onPrioritize: onPrioritize
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upload queue")
    }

    private func title(for phase: UploadDisplayPhase) -> String {
        switch phase {
        case .queued: "Queued"
        case .hashing: "Preparing"
        case .uploading: "In Progress"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        }
    }
}

private struct UploadQueueSection: View {
    let title: String
    let rows: [UploadRowState]
    let onPause: (UUID) -> Void
    let onResume: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onPrioritize: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("\(title) (\(rows.count))")
                    .font(.stratusHeadline)
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    UploadQueueRow(
                        row: row,
                        onPause: onPause,
                        onResume: onResume,
                        onRetry: onRetry,
                        onPrioritize: onPrioritize
                    )
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

private struct UploadQueueRow: View {
    let row: UploadRowState
    let onPause: (UUID) -> Void
    let onResume: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onPrioritize: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ProviderIcon(providerID: row.providerID, size: 28)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(row.fileName)
                        .font(.stratusBody.weight(.medium))
                        .lineLimit(1)
                    Text("\(Int(row.progress * 100))%")
                        .stratusCaption()
                }
                ProgressView(value: row.progress)
                Text(detailLine)
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.md)

            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(formatQueueSpeed(row.speedBPS))
                    .font(.stratusSmallMono)
                Text(formatQueueETA(row.etaSeconds))
                    .stratusCaption()
                actionButton
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var detailLine: String {
        let chunk = row.chunkText.map { " · \($0)" } ?? ""
        return "\(formatQueueBytes(row.bytesTransferred)) / \(formatQueueBytes(row.totalBytes)) · \(row.destinationPath)\(chunk)"
    }

    @ViewBuilder
    private var actionButton: some View {
        switch row.phase {
        case .uploading, .hashing:
            Button("Pause") { onPause(row.id) }
                .buttonStyle(.borderless)
        case .paused:
            Button("Resume") { onResume(row.id) }
                .buttonStyle(.borderless)
        case .failed:
            Button("Retry") { onRetry(row.id) }
                .buttonStyle(.borderless)
        case .queued:
            Button("Prioritize") { onPrioritize(row.id) }
                .buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }
}

private func formatQueueBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func formatQueueSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "0 B/s" }
    return "\(formatQueueBytes(Int64(bps)))/s"
}

private func formatQueueETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
}
