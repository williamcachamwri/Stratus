import Foundation
import os.log

// MARK: - TokenRefresher

// Automatically refreshes OAuth tokens before they expire.
// Checks expiry before every request; refreshes if < 60s remaining.

public actor TokenRefresher {
    public static let shared = TokenRefresher()
    private let vault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "TokenRefresher")

    /// In-flight refresh tasks — deduplicate concurrent requests for same account
    private var refreshTasks: [String: Task<OAuthCredential, any Error>] = [:]

    private init() {}

    // MARK: - Ensure valid token

    public func validToken(providerID: String, accountID: String) async throws -> String {
        guard let credential = try await vault.loadOAuthCredential(providerID: providerID, accountID: accountID) else {
            throw TokenError.noCredential(accountID)
        }
        if !credential.isExpired {
            return credential.accessToken
        }
        let refreshed = try await refresh(providerID: providerID, accountID: accountID, existing: credential)
        return refreshed.accessToken
    }

    // MARK: - Refresh with deduplication

    private func refresh(
        providerID: String,
        accountID: String,
        existing: OAuthCredential
    ) async throws -> OAuthCredential {
        let key = "\(providerID):\(accountID)"

        // If a refresh is already in flight for this account, wait on it
        if let existingTask = refreshTasks[key] {
            return try await existingTask.value
        }

        let task = Task<OAuthCredential, any Error> { [weak self] in
            guard let self else { throw TokenError.internalError }
            let refreshed = try await performRefresh(providerID: providerID, accountID: accountID, existing: existing)
            try await vault.saveOAuthCredential(refreshed, providerID: providerID, accountID: accountID)
            await clearTask(key: key)
            return refreshed
        }

        refreshTasks[key] = task
        return try await task.value
    }

    private func performRefresh(
        providerID: String,
        accountID: String,
        existing: OAuthCredential
    ) async throws -> OAuthCredential {
        guard let refreshToken = existing.refreshToken else {
            throw TokenError.noRefreshToken(accountID)
        }

        // Determine token endpoint per provider and read the OAuth client
        // variables from shared/oauth.config, shared/*.local.config, or env.
        let tokenURL: URL
        switch providerID {
        case "gdrive":
            tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        case "dropbox":
            tokenURL = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        case "onedrive":
            tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case "box":
            tokenURL = URL(string: "https://api.box.com/oauth2/token")!
        default:
            throw TokenError.unsupportedProvider(providerID)
        }

        guard let clientID = SharedConfig.string("CLIENT_ID", providerID: providerID) else {
            throw TokenError.missingClientID(providerID)
        }

        var formItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        if let clientSecret = SharedConfig.string("CLIENT_SECRET", providerID: providerID) {
            formItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }

        var components = URLComponents()
        components.queryItems = formItems

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            logger.error("Token refresh failed for \(providerID)/\(accountID)")
            throw TokenError.refreshFailed
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let newRefreshToken = (json["refresh_token"] as? String) ?? refreshToken
        logger.debug("Refreshed token for \(providerID)/\(accountID)")
        return OAuthCredential(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: existing.scope
        )
    }

    private func clearTask(key: String) {
        refreshTasks.removeValue(forKey: key)
    }
}

public enum TokenError: Error, Sendable {
    case noCredential(String)
    case noRefreshToken(String)
    case refreshFailed
    case unsupportedProvider(String)
    case missingClientID(String)
    case internalError
}
