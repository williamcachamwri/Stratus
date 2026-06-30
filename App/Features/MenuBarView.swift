import StratusCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundColor(.accentColor)
                Text("Stratus")
                    .font(.stratusHeadline)
                Spacer()
                StatusBadge(status: isTransferring ? .active : .idle)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)

            Divider()

            if isTransferring {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        ProgressRing(progress: combinedProgress, size: 16, lineWidth: 2)
                        Text("↑ \(env.uploadSummary.activeCount) · ↓ \(env.downloadSummary.activeCount)")
                            .font(.stratusBody)
                        Spacer()
                        BandwidthLabel(bps: env.uploadBandwidthSnapshot?.currentBPS ?? env.uploadSummary.currentBPS)
                    }
                    ProgressView(value: combinedProgress)
                    Text(
                        "\(env.uploadSummary.queuedCount + env.downloadSummary.queuedCount) queued · \(env.uploadSummary.failedCount + env.downloadSummary.failedCount) failed"
                    )
                    .stratusCaption()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                Divider()
            }

            ForEach(env.accounts.prefix(4), id: \.id) { account in
                HStack(spacing: Spacing.sm) {
                    ProviderIcon(providerID: account.providerID, size: 16)
                    Text(account.displayName)
                        .font(.stratusBody)
                    Spacer()
                    StatusBadge(status: .idle)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
            }

            if env.accounts.isEmpty {
                Text("No accounts")
                    .font(.stratusBody)
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
            }

            Divider()

            Button("Sync All Now") {
                Task { await env.syncEngine.syncAll() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            Button("Open Stratus") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .padding(.bottom, Spacing.sm)
        }
        .frame(width: 260)
    }

    private var isTransferring: Bool {
        env.uploadSummary.activeCount > 0 || env.downloadSummary.activeCount > 0
    }

    private var combinedProgress: Double {
        let transferred = env.uploadSummary.bytesTransferred + env.downloadSummary.bytesReceived
        let total = env.uploadSummary.totalBytes + env.downloadSummary.totalBytes
        guard total > 0 else { return 0 }
        return min(1, Double(transferred) / Double(total))
    }
}
