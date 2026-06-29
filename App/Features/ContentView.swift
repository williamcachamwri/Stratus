import SwiftUI
import StratusCore

struct ContentView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: AppTab = .accounts
    @State private var inspectorVisible = true

    enum AppTab: String, CaseIterable, Identifiable {
        case accounts  = "Accounts"
        case uploads   = "Uploads"
        case downloads = "Downloads"
        case sync      = "Sync"
        case mounts    = "Mounts"
        case browse    = "Files"
        case prefs     = "Preferences"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .accounts: return "person.crop.circle.badge.plus"
            case .uploads:  return "arrow.up.circle"
            case .downloads: return "arrow.down.circle"
            case .sync:     return "arrow.triangle.2.circlepath"
            case .mounts:   return "externaldrive"
            case .browse:   return "folder"
            case .prefs:    return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Library") {
                    ForEach(AppTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .tag(tab)
                    }
                }

                Section("Accounts") {
                    if env.accounts.isEmpty {
                        Label("Add account…", systemImage: "plus.circle")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(env.accounts, id: \.id) { account in
                            HStack(spacing: Spacing.sm) {
                                ProviderIcon(providerID: account.providerID, size: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.email ?? account.displayName)
                                        .font(.stratusBody)
                                        .lineLimit(1)
                                    if account.email != nil {
                                        Text(account.displayName)
                                            .font(.caption2)
                                            .foregroundColor(.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Finder") {
                    Label("\(env.mountRows.count) mounted", systemImage: "externaldrive")
                    Label("Open Mount Manager", systemImage: "sidebar.left")
                        .tag(AppTab.mounts)
                }

                Section("Transfers") {
                    Button { selectedTab = .uploads } label: {
                        Label("\(env.uploadSummary.activeCount) uploading", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.plain)
                    Button { selectedTab = .downloads } label: {
                        Label("\(env.downloadSummary.activeCount) downloading", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    Button { selectedTab = .uploads } label: {
                        Label("\(env.uploadSummary.queuedCount + env.downloadSummary.queuedCount) queued", systemImage: "clock")
                    }
                    .buttonStyle(.plain)
                    Button { selectedTab = .uploads } label: {
                        Label("\(env.uploadSummary.failedCount + env.downloadSummary.failedCount) failed", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain)
                }

                Section("Sync Pairs") {
                    if env.activeSyncPairs.isEmpty {
                        Label("No sync pairs", systemImage: "folder.badge.questionmark")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(env.activeSyncPairs, id: \.id) { pair in
                            Label(pair.localPath.lastPathComponent, systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    selectedContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if inspectorVisible {
                        Divider()
                        TransferInspectorView(
                            uploadSummary: env.uploadSummary,
                            downloadSummary: env.downloadSummary,
                            selectedTab: selectedTab
                        )
                            .frame(width: 280)
                    }
                }

                Divider()
                TransferStatusBar(
                    uploadSummary: env.uploadSummary,
                    downloadSummary: env.downloadSummary,
                    isOnline: env.isOnline
                )
            }
            .navigationTitle(selectedTab.rawValue)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        selectedTab = .accounts
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }

                    Button {
                        inspectorVisible.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .accounts: AccountsView()
        case .uploads:  UploadCenterView()
        case .downloads: DownloadCenterView()
        case .sync:     SyncManagerView()
        case .mounts:   MountManagerView()
        case .browse:   FileBrowserView()
        case .prefs:    PreferencesView()
        }
    }
}

// MARK: - Inspector

private struct TransferInspectorView: View {
    let uploadSummary: UploadDashboardSummary
    let downloadSummary: DownloadDashboardSummary
    let selectedTab: ContentView.AppTab

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Inspector")
                .font(.stratusHeadline)

            InspectorGroup(title: "Selection") {
                InspectorRow(label: "View", value: selectedTab.rawValue)
                InspectorRow(label: "Status", value: uploadSummary.activeCount + downloadSummary.activeCount > 0 ? "Transferring" : "Idle")
            }

            InspectorGroup(title: "Upload Session") {
                InspectorRow(label: "Progress", value: "\(Int(uploadSummary.progress * 100))%")
                InspectorRow(label: "Transferred", value: formatStatusBytes(uploadSummary.bytesTransferred))
                InspectorRow(label: "Total", value: formatStatusBytes(uploadSummary.totalBytes))
                InspectorRow(label: "Current", value: formatStatusSpeed(uploadSummary.currentBPS))
                InspectorRow(label: "Peak", value: formatStatusSpeed(uploadSummary.peakBPS))
                InspectorRow(label: "ETA", value: formatStatusETA(uploadSummary.etaSeconds))
            }

            InspectorGroup(title: "Files") {
                InspectorRow(label: "Uploading", value: "\(uploadSummary.activeCount)")
                InspectorRow(label: "Downloading", value: "\(downloadSummary.activeCount)")
                InspectorRow(label: "Queued", value: "\(uploadSummary.queuedCount + downloadSummary.queuedCount)")
                InspectorRow(label: "Paused", value: "\(uploadSummary.pausedCount + downloadSummary.pausedCount)")
                InspectorRow(label: "Failed", value: "\(uploadSummary.failedCount + downloadSummary.failedCount)")
                InspectorRow(label: "Completed", value: "\(uploadSummary.completedCount + downloadSummary.completedCount)")
            }

            Spacer()
        }
        .padding(Spacing.lg)
        .background(Color.surfacePrimary)
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.textTertiary)
                .tracking(0.5)
            VStack(spacing: Spacing.xs) {
                content()
            }
        }
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.textSecondary)
            Spacer(minLength: Spacing.md)
            Text(value)
                .font(.stratusSmallMono)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

// MARK: - Bottom Status Bar

private struct TransferStatusBar: View {
    let uploadSummary: UploadDashboardSummary
    let downloadSummary: DownloadDashboardSummary
    let isOnline: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "wifi" : "wifi.slash")
            Divider().frame(height: 14)
            Text("↑ \(uploadSummary.activeCount) uploading")
            Text("↓ \(downloadSummary.activeCount) downloading")
            Text("·")
            Text("↑ \(formatStatusSpeed(uploadSummary.currentBPS))")
            Text("↓ \(formatStatusSpeed(downloadSummary.currentBPS))")
            Text("·")
            Text("\(uploadSummary.queuedCount + downloadSummary.queuedCount) files remaining")
            Text("·")
            Text("ETA \(formatStatusETA(uploadSummary.etaSeconds ?? downloadSummary.etaSeconds))")
            Spacer()
            Text("↑ \(formatStatusBytes(uploadSummary.bytesTransferred)) / \(formatStatusBytes(uploadSummary.totalBytes)) · ↓ \(formatStatusBytes(downloadSummary.bytesReceived)) / \(formatStatusBytes(downloadSummary.totalBytes))")
                .font(.stratusSmallMono)
        }
        .font(.caption)
        .foregroundColor(.textSecondary)
        .padding(.horizontal, Spacing.md)
        .frame(height: 28)
        .background(Color.surfacePrimary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

private func formatStatusBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func formatStatusSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "0 B/s" }
    return "\(formatStatusBytes(Int64(bps)))/s"
}

private func formatStatusETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds) % 60)s" }
    return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600)) / 60)m"
}
