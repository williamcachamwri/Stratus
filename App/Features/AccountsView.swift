import SwiftUI
import StratusCore

struct AccountsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showAddSheet = false
    @State private var selectedAccount: CloudAccount?

    var body: some View {
        Group {
            if env.accounts.isEmpty {
                EmptyStateView(
                    icon: "cloud.slash",
                    title: "No Cloud Accounts",
                    subtitle: "Add an account to start managing your cloud storage.",
                    actionTitle: "Add Account",
                    action: { showAddSheet = true }
                )
            } else {
                List(env.accounts, id: \.id, selection: $selectedAccount) { account in
                    AccountRowView(account: account)
                        .tag(account)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                env.removeAccount(account)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet()
                .environmentObject(env)
        }
    }
}

// MARK: - AccountRowView

private struct AccountRowView: View {
    let account: CloudAccount

    var body: some View {
        HStack(spacing: Spacing.md) {
            ProviderIcon(providerID: account.providerID, size: 36)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(account.displayName)
                    .font(.stratusHeadline)
                Text(account.email ?? account.id)
                    .stratusCaption()
            }
            Spacer()
            StatusBadge(status: .idle)
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - AddAccountSheet

private struct AddAccountSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var providers: [(id: String, name: String)] = [
        ("gdrive", "Google Drive"),
        ("dropbox", "Dropbox"),
        ("onedrive", "OneDrive"),
        ("s3", "Amazon S3"),
        ("sftp", "SFTP Server"),
        ("webdav", "WebDAV"),
        ("wasabi", "Wasabi"),
        ("backblaze_b2", "Backblaze B2"),
        ("cloudflare_r2", "Cloudflare R2"),
    ]

    var body: some View {
        NavigationStack {
            List(providers, id: \.id) { provider in
                Button {
                    // Trigger provider-specific auth flow
                    addAccount(providerID: provider.id, name: provider.name)
                } label: {
                    HStack(spacing: Spacing.md) {
                        ProviderIcon(providerID: provider.id)
                        Text(provider.name)
                            .font(.stratusBody)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(width: 360, height: 500)
    }

    private func addAccount(providerID: String, name: String) {
        let account = CloudAccount(
            id: UUID().uuidString,
            providerID: providerID,
            displayName: name,
            email: nil
        )
        env.addAccount(account)
        dismiss()
    }
}
