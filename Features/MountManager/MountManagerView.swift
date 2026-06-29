import SwiftUI
import StratusCore

public struct MountManagerView: View {
    @EnvironmentObject private var env: AppEnvironment
    public let mounts: [MountRow]?

    public init(mounts: [MountRow]? = nil) {
        self.mounts = mounts
    }

    private var visibleMounts: [MountRow] { mounts ?? env.mountRows }
    private var mountedAccountIDs: Set<String> { Set(visibleMounts.map(\.accountID)) }
    private var unmountedAccounts: [CloudAccount] { env.accounts.filter { !mountedAccountIDs.contains($0.id) } }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Mount Manager")
                        .font(.stratusTitle)
                    Text("Finder Locations volumes backed by File Provider and offline cache.")
                        .stratusCaption()
                }
                Spacer()
                Menu("Mount Account") {
                    if unmountedAccounts.isEmpty {
                        Text("All accounts are mounted")
                    } else {
                        ForEach(unmountedAccounts, id: \.id) { account in
                            Button("Stratus - \(account.displayName)") {
                                Task { await env.mountAccount(account) }
                            }
                        }
                    }
                }
                .disabled(env.accounts.isEmpty)
            }

            if env.accounts.isEmpty {
                EmptyStateView(
                    icon: "externaldrive.badge.plus",
                    title: "No accounts to mount",
                    subtitle: "Add a provider account first, then Stratus can expose it in Finder Locations."
                )
            } else if visibleMounts.isEmpty {
                EmptyStateView(
                    icon: "externaldrive.badge.questionmark",
                    title: "No mounted accounts",
                    subtitle: "Choose Mount Account to register a File Provider domain in Finder."
                )
            } else {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(visibleMounts) { mount in
                        MountItemView(row: mount) {
                            if let account = env.accounts.first(where: { $0.id == mount.accountID }) {
                                Task { await env.unmountAccount(account) }
                            }
                        }
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .background(Color.surfaceSecondary)
        .task { await env.refreshMountRows() }
    }
}

public struct MountRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case mounted = "Mounted"
        case syncing = "Syncing"
        case offline = "Offline"
        case error = "Error"

        public init(_ status: FileProviderDomainStatus) {
            switch status {
            case .mounted: self = .mounted
            case .unmounted: self = .offline
            case .error: self = .error
            }
        }
    }

    public let id: String
    public let accountID: String
    public let accountName: String
    public let providerID: String
    public let mountPath: String
    public let status: Status
    public let statusMessage: String?
    public let quotaUsed: Int64
    public let quotaTotal: Int64?
    public let cacheUsed: Int64

    public init(
        id: String,
        accountID: String,
        accountName: String,
        providerID: String,
        mountPath: String,
        status: Status,
        statusMessage: String? = nil,
        quotaUsed: Int64,
        quotaTotal: Int64?,
        cacheUsed: Int64
    ) {
        self.id = id
        self.accountID = accountID
        self.accountName = accountName
        self.providerID = providerID
        self.mountPath = mountPath
        self.status = status
        self.statusMessage = statusMessage
        self.quotaUsed = quotaUsed
        self.quotaTotal = quotaTotal
        self.cacheUsed = cacheUsed
    }
}

private struct MountItemView: View {
    let row: MountRow
    let unmount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(row.status == .error ? .red : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(row.accountName)
                        .font(.stratusBody.weight(.medium))
                    Text(row.mountPath)
                        .font(.stratusSmallMono)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
                Text(row.status.rawValue)
                    .stratusCaption()
                Button("Unmount", action: unmount)
                    .disabled(row.status == .error)
            }

            HStack(spacing: Spacing.lg) {
                Text("Provider: \(row.providerID)")
                    .stratusCaption()
                Text("Quota: \(formatMountBytes(row.quotaUsed)) / \(row.quotaTotal.map(formatMountBytes) ?? "Unlimited")")
                    .stratusCaption()
                Text("Cache: \(formatMountBytes(row.cacheUsed))")
                    .stratusCaption()
            }

            if let message = row.statusMessage, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .cardStyle()
    }

    private var statusIcon: String {
        switch row.status {
        case .mounted: return "externaldrive"
        case .syncing: return "externaldrive.badge.icloud"
        case .offline: return "externaldrive.badge.questionmark"
        case .error: return "externaldrive.badge.exclamationmark"
        }
    }
}

private func formatMountBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
