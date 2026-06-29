import SwiftUI
import StratusCore

struct SyncManagerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showAddSheet = false

    var body: some View {
        Group {
            if env.activeSyncPairs.isEmpty {
                EmptyStateView(
                    icon: "arrow.triangle.2.circlepath",
                    title: "No Sync Pairs",
                    subtitle: "Create a sync pair to keep a local folder in sync with your cloud storage.",
                    actionTitle: "Add Sync Pair",
                    action: { showAddSheet = true }
                )
            } else {
                List {
                    if !env.pendingConflicts.isEmpty {
                        Section("Conflicts (\(env.pendingConflicts.count))") {
                            ForEach(env.pendingConflicts, id: \.id) { conflict in
                                ConflictRowView(conflict: conflict)
                            }
                        }
                    }
                    Section("Active Sync Pairs") {
                        ForEach(env.activeSyncPairs, id: \.id) { pair in
                            SyncPairRowView(pair: pair) {
                                Task { await env.syncEngine.syncNow(pairID: pair.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Sync Manager")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: {
                    Label("Add Pair", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    Task { await env.syncEngine.syncAll() }
                } label: {
                    Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSyncPairSheet()
                .environmentObject(env)
        }
    }
}

// MARK: - SyncPairRowView

private struct SyncPairRowView: View {
    let pair: SyncPair
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundColor(.syncRunning)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(pair.localPath.lastPathComponent)
                    .font(.stratusHeadline)
                HStack(spacing: Spacing.xs) {
                    Text(pair.localPath.path)
                    Image(systemName: syncModeIcon(pair.mode))
                        .font(.caption)
                    Text(pair.remotePath.path)
                }
                .stratusCaption()
                .lineLimit(1)
            }
            Spacer()
            if let lastSync = pair.lastSyncedAt {
                Text(lastSync, style: .relative)
                    .stratusCaption()
            }
            Button {
                onSync()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, Spacing.xs)
    }

    private func syncModeIcon(_ mode: SyncMode) -> String {
        switch mode {
        case .oneWayUpload:   return "arrow.up"
        case .oneWayDownload: return "arrow.down"
        case .bidirectional:  return "arrow.up.arrow.down"
        case .mirror, .backup: return "arrow.up.doc"
        }
    }
}

// MARK: - ConflictRowView

private struct ConflictRowView: View {
    let conflict: SyncConflict

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.syncConflict)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(conflict.localURL.lastPathComponent)
                    .font(.stratusHeadline)
                Text("Local: \(conflict.localModDate, style: .relative) · Remote: \(conflict.remoteModDate, style: .relative)")
                    .stratusCaption()
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - AddSyncPairSheet (simplified)

private struct AddSyncPairSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: String = ""
    @State private var localPathString: String = ""
    @State private var remotePath: String = "/"
    @State private var mode: SyncMode = .bidirectional

    var body: some View {
        NavigationStack {
            Form {
                Picker("Account", selection: $selectedAccountID) {
                    ForEach(env.accounts, id: \.id) { a in
                        Text(a.displayName).tag(a.id)
                    }
                }
                TextField("Local Folder", text: $localPathString)
                TextField("Remote Path", text: $remotePath)
                Picker("Sync Mode", selection: $mode) {
                    ForEach(SyncMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
            }
            .navigationTitle("New Sync Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addPair()
                        dismiss()
                    }
                    .disabled(localPathString.isEmpty || selectedAccountID.isEmpty)
                }
            }
        }
        .frame(width: 400, height: 280)
        .onAppear {
            selectedAccountID = env.accounts.first?.id ?? ""
        }
    }

    private func addPair() {
        let localURL = URL(fileURLWithPath: localPathString)
        let pair = SyncPair(
            localPath: localURL,
            remotePath: CloudPath(remotePath),
            accountID: selectedAccountID,
            mode: mode
        )
        Task { await env.addSyncPair(pair) }
    }
}
