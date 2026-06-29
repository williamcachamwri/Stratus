import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var snapshot: BWSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundColor(.accentColor)
                Text("Stratus")
                    .font(.stratusHeadline)
                Spacer()
                StatusBadge(status: env.activeUploads > 0 ? .active : .idle)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)

            Divider()

            // Upload status
            if env.activeUploads > 0 {
                HStack(spacing: Spacing.sm) {
                    ProgressRing(progress: 0.5, size: 16, lineWidth: 2)
                    Text("\(env.activeUploads) uploading")
                        .font(.stratusBody)
                    Spacer()
                    if let snap = snapshot {
                        BandwidthLabel(bps: snap.currentBPS)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                Divider()
            }

            // Accounts
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

            // Actions
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
        .onAppear { listenForBandwidth() }
    }

    private func listenForBandwidth() {
        Task { @MainActor in
            let monitor = BandwidthMonitor()
            for await snap in await monitor.updates {
                snapshot = snap
            }
        }
    }
}
