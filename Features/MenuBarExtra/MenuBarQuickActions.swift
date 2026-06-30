import StratusCore
import SwiftUI

public struct MenuBarQuickActions: View {
    @EnvironmentObject private var env: AppEnvironment
    public var openWindow: () -> Void

    public init(openWindow: @escaping () -> Void = {}) {
        self.openWindow = openWindow
    }

    public var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button("Pause All") {
                    Task { await env.uploadEngine.pauseAll() }
                }
                .disabled(env.uploadSummary.activeCount == 0)

                Button("Resume All") {
                    Task { await env.uploadEngine.resumeAll() }
                }
                .disabled(env.uploadSummary.pausedCount == 0 && env.uploadSummary.queuedCount == 0)
            }

            Button("Open Stratus") {
                openWindow()
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

public struct MenuBarTransferSummary: View {
    public let summary: UploadDashboardSummary

    public init(summary: UploadDashboardSummary) {
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .foregroundColor(.secondary)
                Text("\(summary.activeCount) active · \(formatMenuSpeed(summary.currentBPS))")
                    .font(.stratusSmallMono)
                Spacer()
                Text("\(Int(summary.progress * 100))%")
                    .font(.stratusSmallMono)
            }
            ProgressView(value: summary.progress)
            Text(
                "\(summary.queuedCount) queued · \(summary.failedCount) failed · ETA \(formatMenuETA(summary.etaSeconds))"
            )
            .stratusCaption()
        }
        .padding(Spacing.md)
    }
}

private func formatMenuSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "0 B/s" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return "\(formatter.string(fromByteCount: Int64(bps)))/s"
}

private func formatMenuETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    return "\(Int(seconds / 60))m"
}
