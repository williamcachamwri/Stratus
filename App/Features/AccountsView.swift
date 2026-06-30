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
                    subtitle: "Add a real account to start browsing, mounting, uploading, and syncing.",
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
                Text(primaryTitle)
                    .font(.stratusHeadline)
                    .lineLimit(1)
                if let secondaryTitle {
                    Text(secondaryTitle)
                        .stratusCaption()
                        .lineLimit(1)
                }
            }
            Spacer()
            StatusBadge(status: .idle)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var primaryTitle: String {
        "\(account.email ?? account.displayName) - \(providerName)"
    }

    private var secondaryTitle: String? {
        account.email == nil ? nil : account.displayName
    }

    private var providerName: String {
        ProviderDefinitionCatalog.shared.displayName(for: account.providerID)
    }
}

// MARK: - AddAccountSheet

private struct AddAccountSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = ProviderDefinitionCatalog.shared

    @State private var selectedProviderID: String?
    @State private var displayName = ""
    @State private var email = ""
    @State private var endpointURL = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var basePath = "/"
    @State private var useTLS = false
    @State private var usePathStyleURL = false
    @State private var useTransferAcceleration = false
    @State private var oauthClientID = ""
    @State private var oauthRedirectURI = "stratus://oauth/callback"
    @State private var oauthScopes = ""
    @State private var oauthCredential: OAuthCredential?
    @State private var isAuthorizing = false
    @State private var errorMessage: String?

    private var selectedDefinition: ProviderDefinition? {
        selectedProviderID.flatMap { catalog.definition(for: $0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let definition = selectedDefinition {
                    accountForm(definition: definition)
                } else {
                    ProviderPickerView(showsHeader: false) { choice in
                        selectedProviderID = choice.id
                        displayName = choice.title
                        applySharedDefaults(for: choice.id)
                    }
                }
            }
            .navigationTitle(selectedDefinition?.displayName ?? "Choose Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedDefinition == nil ? "Cancel" : "Back") {
                        if selectedDefinition == nil {
                            dismiss()
                        } else {
                            selectedProviderID = nil
                            errorMessage = nil
                        }
                    }
                }
                if let definition = selectedDefinition {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            Task { await saveAccount(definition: definition) }
                        }
                        .disabled(!canSave(definition: definition))
                    }
                }
            }
        }
        .frame(width: 520, height: 620)
    }

    @ViewBuilder
    private func accountForm(definition: ProviderDefinition) -> some View {
        Form {
            Section("Account") {
                TextField("Display name", text: $displayName)
                TextField("Email or label", text: $email)
                HStack {
                    Text("Provider")
                    Spacer()
                    Text(definition.displayName)
                        .foregroundColor(.secondary)
                }
                Text(definition.capabilitiesText)
                    .stratusCaption()
            }

            if isS3(definition) {
                Section("S3 Endpoint") {
                    TextField("Bucket", text: $bucket)
                    TextField("Region", text: $region)
                    TextField("Custom endpoint URL", text: $endpointURL)
                    Toggle("Path-style URLs", isOn: $usePathStyleURL)
                    Toggle("Transfer acceleration", isOn: $useTransferAcceleration)
                }
                Section("Credentials") {
                    TextField("Access key ID", text: $accessKeyID)
                    SecureField("Secret access key", text: $secretAccessKey)
                    SecureField("Session token (optional)", text: $sessionToken)
                }
            } else if definition.kind == "ssh-file-transfer" {
                Section("SFTP Server") {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            } else if definition.kind == "http-file-transfer" {
                Section("WebDAV Server") {
                    TextField("Base URL", text: $endpointURL)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            } else if definition.kind == "ftp-file-transfer" {
                Section("FTP / FTPS Server") {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    TextField("Base path", text: $basePath)
                    Toggle("Use implicit FTPS", isOn: $useTLS)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            } else if definition.isOAuthProvider {
                Section("OAuth") {
                    TextField("Client ID", text: $oauthClientID)
                    TextField("Redirect URI", text: $oauthRedirectURI)
                    TextField("Scopes", text: $oauthScopes)
                    Text("Defaults load from shared/oauth.config, shared/*.local.config, or matching environment variables.")
                        .stratusCaption()
                    Button(isAuthorizing ? "Authorizing…" : "Authorize in Browser") {
                        Task { await authorizeOAuth(definition: definition) }
                    }
                    .disabled(isAuthorizing || oauthClientID.isEmpty || oauthRedirectURI.isEmpty)
                    if oauthCredential != nil {
                        Label("OAuth token received and ready to save", systemImage: "checkmark.seal")
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Section("Provider") {
                    Text("This provider is configured by macOS or the File Provider extension. No demo account will be created; only a persisted account row is saved.")
                        .stratusCaption()
                }
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func canSave(definition: ProviderDefinition) -> Bool {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isS3(definition) {
            return !bucket.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
        }
        switch definition.kind {
        case "ssh-file-transfer", "ftp-file-transfer":
            return !host.isEmpty && !username.isEmpty && !password.isEmpty
        case "http-file-transfer":
            return URL(string: endpointURL) != nil && !username.isEmpty && !password.isEmpty
        default:
            return definition.isOAuthProvider ? oauthCredential != nil : true
        }
    }

    private func saveAccount(definition: ProviderDefinition) async {
        let accountID = UUID().uuidString
        let account = CloudAccount(
            id: accountID,
            providerID: definition.id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : email
        )
        let config = makeConfig(definition: definition, accountID: accountID)

        do {
            if isS3(definition) {
                try await CredentialVault.shared.saveAPIKeyCredential(
                    APIKeyCredential(
                        accessKeyID: accessKeyID,
                        secretAccessKey: secretAccessKey,
                        sessionToken: sessionToken.isEmpty ? nil : sessionToken,
                        region: region
                    ),
                    providerID: definition.id,
                    accountID: accountID
                )
            } else if definition.kind == "ssh-file-transfer" || definition.kind == "http-file-transfer" || definition.kind == "ftp-file-transfer" {
                try await CredentialVault.shared.saveBasicCredential(
                    BasicCredential(username: username, password: password),
                    providerID: definition.id,
                    accountID: accountID
                )
            } else if let oauthCredential {
                try await CredentialVault.shared.saveOAuthCredential(
                    oauthCredential,
                    providerID: definition.id,
                    accountID: accountID
                )
            }

            await MainActor.run {
                env.addAccount(account, config: config)
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func authorizeOAuth(definition: ProviderDefinition) async {
        guard
            let authURLString = definition.authURL,
            let tokenURLString = definition.tokenURL,
            let authURL = URL(string: authURLString),
            let tokenURL = URL(string: tokenURLString)
        else { return }

        isAuthorizing = true
        defer { isAuthorizing = false }
        do {
            let tokens = try await OAuthManager.shared.authenticate(
                provider: definition.displayName,
                clientID: oauthClientID,
                redirectURI: oauthRedirectURI,
                scopes: oauthScopes.split(separator: " ").map(String.init),
                authorizationURL: authURL,
                tokenURL: tokenURL,
                clientSecret: SharedConfig.string("CLIENT_SECRET", providerID: definition.id)
            )
            oauthCredential = OAuthCredential(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                scope: tokens.scope,
                tokenType: tokens.tokenType
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeConfig(definition: ProviderDefinition, accountID: String) -> ProviderAccountConfig {
        ProviderAccountConfig(
            accountID: accountID,
            providerID: definition.id,
            endpointURL: endpointURL.isEmpty ? nil : endpointURL,
            region: region.isEmpty ? nil : region,
            bucket: bucket.isEmpty ? nil : bucket,
            host: host.isEmpty ? nil : host,
            port: Int(port),
            username: username.isEmpty ? nil : username,
            basePath: basePath.isEmpty ? nil : basePath,
            useTLS: useTLS,
            usePathStyleURL: usePathStyleURL,
            useTransferAcceleration: useTransferAcceleration
        )
    }

    private func applySharedDefaults(for providerID: String) {
        oauthClientID = SharedConfig.string("CLIENT_ID", providerID: providerID) ?? ""
        oauthRedirectURI = SharedConfig.string("REDIRECT_URI", providerID: providerID) ?? defaultRedirectURI(for: providerID)
        oauthScopes = SharedConfig.string("SCOPES", providerID: providerID) ?? defaultScopes(for: providerID)

        endpointURL = SharedConfig.string("ENDPOINT_URL", providerID: providerID) ?? ""
        region = SharedConfig.string("REGION", providerID: providerID) ?? "us-east-1"
        bucket = SharedConfig.string("BUCKET", providerID: providerID) ?? ""
        host = SharedConfig.string("HOST", providerID: providerID) ?? ""
        port = SharedConfig.string("PORT", providerID: providerID) ?? ""
        username = SharedConfig.string("USERNAME", providerID: providerID) ?? ""
        password = SharedConfig.string("PASSWORD", providerID: providerID) ?? ""
        accessKeyID = SharedConfig.string("ACCESS_KEY_ID", providerID: providerID) ?? ""
        secretAccessKey = SharedConfig.string("SECRET_ACCESS_KEY", providerID: providerID) ?? ""
        sessionToken = SharedConfig.string("SESSION_TOKEN", providerID: providerID) ?? ""
        basePath = SharedConfig.string("BASE_PATH", providerID: providerID) ?? "/"
        useTLS = SharedConfig.bool("USE_TLS", providerID: providerID)
        usePathStyleURL = SharedConfig.bool("USE_PATH_STYLE_URL", providerID: providerID)
        useTransferAcceleration = SharedConfig.bool("USE_TRANSFER_ACCELERATION", providerID: providerID)
    }

    private func defaultRedirectURI(for providerID: String) -> String {
        switch providerID {
        case "gdrive":
            // Google native-app clients use a reversed-client-ID URI scheme.
            // Derive it from the configured CLIENT_ID so it matches what
            // Google Cloud Console generates automatically for Desktop/iOS clients.
            if let clientID = SharedConfig.string("CLIENT_ID", providerID: providerID),
               clientID.hasSuffix(".apps.googleusercontent.com") {
                let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
                return "com.googleusercontent.apps.\(prefix):/oauth2redirect"
            }
            return "com.stratus.cloudmanager:/oauth2callback"
        case "dropbox": return "com.stratus.cloudmanager:/dropbox/callback"
        case "onedrive": return "com.stratus.cloudmanager://auth/onedrive"
        case "box": return "stratus://oauth/box"
        default: return "stratus://oauth/callback"
        }
    }

    private func isS3(_ definition: ProviderDefinition) -> Bool {
        definition.kind == "s3" || definition.kind == "s3-compatible"
    }

    private func defaultScopes(for providerID: String) -> String {
        switch providerID {
        case "gdrive": return "https://www.googleapis.com/auth/drive"
        case "dropbox": return "files.content.write files.content.read account_info.read"
        case "onedrive": return "Files.ReadWrite offline_access User.Read"
        case "box": return "root_readwrite"
        default: return ""
        }
    }
}
