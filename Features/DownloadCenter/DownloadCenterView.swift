import SwiftUI
import StratusCore

public struct DownloadCenterView: View {
    private let rows: [DownloadRow]

    public init(rows: [DownloadRow] = DownloadRow.placeholderRows) {
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Download Center")
                        .font(.stratusTitle)
                    Text("Range downloads, resume state, and verification are shown per file.")
                        .stratusCaption()
                }
                Spacer()
                Button("Pause All") {}
                    .disabled(rows.allSatisfy { $0.phase != .downloading })
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
        .padding(Spacing.lg)
        .background(Color.surfaceSecondary)
    }
}

public struct DownloadRow: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable {
        case queued = "Queued"
        case downloading = "Downloading"
        case verifying = "Verifying"
        case completed = "Completed"
        case failed = "Failed"
    }

    public let id: UUID
    public let fileName: String
    public let sourcePath: String
    public let phase: Phase
    public let progress: Double
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let speedBPS: Double
    public let etaSeconds: Double?
    public let rangeText: String

    public init(
        id: UUID = UUID(),
        fileName: String,
        sourcePath: String,
        phase: Phase,
        progress: Double,
        bytesReceived: Int64,
        totalBytes: Int64,
        speedBPS: Double,
        etaSeconds: Double?,
        rangeText: String
    ) {
        self.id = id
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.phase = phase
        self.progress = progress
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.speedBPS = speedBPS
        self.etaSeconds = etaSeconds
        self.rangeText = rangeText
    }

    public static let placeholderRows = [
        DownloadRow(
            fileName: "archive.zip",
            sourcePath: "/S3/backups/archive.zip",
            phase: .queued,
            progress: 0,
            bytesReceived: 0,
            totalBytes: 1_200_000_000,
            speedBPS: 0,
            etaSeconds: nil,
            rangeText: "Waiting for available range slots"
        )
    ]
}

private struct DownloadItemRow: View {
    let row: DownloadRow

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(row.fileName)
                        .font(.stratusBody.weight(.medium))
                    Text(row.phase.rawValue)
                        .stratusCaption()
                }
                ProgressView(value: row.progress)
                Text("\(formatTransferBytes(row.bytesReceived)) / \(formatTransferBytes(row.totalBytes)) · \(row.sourcePath) · \(row.rangeText)")
                    .font(.stratusSmallMono)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(formatTransferSpeed(row.speedBPS))
                    .font(.stratusSmallMono)
                Text(formatTransferETA(row.etaSeconds))
                    .stratusCaption()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
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
