import Foundation

// MARK: - CloudProviderFactory

/// Builds provider actors from persisted account/config data.
///
/// This is shared by the main app and the File Provider extension. The extension
/// cannot reuse in-memory providers from the app process, so every domain resolve
/// must recreate the correct provider from disk/keychain state.
public enum CloudProviderFactory {
    public static func makeProvider(
        for account: CloudAccount,
        config: ProviderAccountConfig?,
        credentialVault: CredentialVault = .shared
    ) async -> (any CloudProvider)? {
        switch account.providerID {
        case "s3", "wasabi", "backblaze_b2", "cloudflare_r2":
            guard let config, let bucket = config.bucket, !bucket.isEmpty else { return nil }
            let endpoint = config.endpointURL.flatMap(URL.init(string:))
            let s3Config = S3Configuration(
                endpoint: endpoint,
                region: config.region ?? "us-east-1",
                bucket: bucket,
                useTransferAcceleration: config.useTransferAcceleration,
                usePathStyleURL: config.usePathStyleURL
            )
            return S3Provider(
                id: account.providerID,
                displayName: displayName(for: account.providerID),
                iconName: account.providerID,
                config: s3Config
            )

        case "gdrive":
            return GoogleDriveProvider()

        case "dropbox":
            return DropboxProvider()

        case "onedrive":
            return OneDriveProvider()

        case "box":
            return BoxProvider()

        case "sftp":
            guard
                let config,
                let host = config.host,
                let username = config.username,
                let basic = try? await credentialVault.loadBasicCredential(
                    providerID: account.providerID,
                    accountID: account.id
                )
            else { return nil }
            let provider = SFTPProvider()
            await provider.registerConnection(
                SFTPProvider.ConnectionInfo(
                    host: host,
                    port: config.port ?? 22,
                    username: username,
                    authMethod: .password(basic.password)
                ),
                accountID: account.id
            )
            return provider

        case "webdav":
            guard let urlString = config?.endpointURL, let url = URL(string: urlString) else { return nil }
            let provider = WebDAVProvider()
            await provider.registerBaseURL(url, accountID: account.id)
            return provider

        case "ftp":
            guard
                let config,
                let host = config.host,
                let basic = try? await credentialVault.loadBasicCredential(
                    providerID: account.providerID,
                    accountID: account.id
                )
            else { return nil }
            let provider = FTPProvider()
            await provider.registerConfig(
                FTPProvider.FTPConfig(
                    host: host,
                    port: config.port ?? 21,
                    usesTLS: config.useTLS,
                    username: basic.username,
                    password: basic.password,
                    basePath: config.basePath ?? "/"
                ),
                accountID: account.id
            )
            return provider

        default:
            return nil
        }
    }

    public static func displayName(for providerID: String) -> String {
        switch providerID {
        case "s3": "Amazon S3"
        case "wasabi": "Wasabi"
        case "backblaze_b2": "Backblaze B2"
        case "cloudflare_r2": "Cloudflare R2"
        case "gdrive": "Google Drive"
        case "dropbox": "Dropbox"
        case "onedrive": "OneDrive"
        case "box": "Box"
        case "sftp": "SFTP"
        case "webdav": "WebDAV"
        case "ftp": "FTP"
        default: providerID
        }
    }
}
