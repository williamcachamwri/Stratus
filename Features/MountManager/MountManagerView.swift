import SwiftUI
import StratusCore

public struct MountManagerView: View {
    public let mounts: [MountRow]

    public init(mounts: [MountRow] = []) {
        self.mounts = mounts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Mount Manager")
                        .font(.stratusTitle)
                    Text("Finder volumes backed by File Provider and offline cache.")
                        .stratusCaption()
                }
                Spacer()
                Button("Mount Account") {}
            }

            if mounts.isEmpty {
                EmptyStateView(
                    icon: "externaldrive.badge.questionmark",
                    title: "No mounted accounts",
                    subtitle: "Mount rows will be populated from File Provider mount state, not placeholder demo data."
                )
            } else {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(mounts) { mount in
                        MountItemView(row: mount)
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .background(Color.surfaceSecondary)
    }
}

public struct MountRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case mounted = "Mounted"
        case syncing = "Syncing"
        case offline = "Offline"
        case error = "Error"
    }

    public let id: UUID
    public let accountName: String
    public let providerID: String
    public let mountPath: String
    public let status: Status
    public let quotaUsed: Int64
    public let quotaTotal: Int64?
    public let cacheUsed: Int64

    public init(
        id: UUID = UUID(),
        accountName: String,
        providerID: String,
        mountPath: String,
        status: Status,
        quotaUsed: Int64,
        quotaTotal: Int64?,
        cacheUsed: Int64
    ) {
        self.id = id
        self.accountName = accountName
        self.providerID = providerID
        self.mountPath = mountPath
        self.status = status
        self.quotaUsed = quotaUsed
        self.quotaTotal = quotaTotal
        self.cacheUsed = cacheUsed
    }
}

private struct MountItemView: View {
    let row: MountRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                ProviderIcon(providerID: row.providerID, size: 28)
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
            }

            HStack(spacing: Spacing.lg) {
                Text("Quota: \(formatMountBytes(row.quotaUsed)) / \(row.quotaTotal.map(formatMountBytes) ?? "Unlimited")")
                    .stratusCaption()
                Text("Cache: \(formatMountBytes(row.cacheUsed))")
                    .stratusCaption()
            }
        }
        .cardStyle()
    }
}

private func formatMountBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
