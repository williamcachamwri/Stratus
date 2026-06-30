import Foundation
import LocalAuthentication
import os.log

// MARK: - Credential Types

public struct OAuthCredential: Sendable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scope: String?
    public let tokenType: String

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60) // 60s buffer
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }
}

public struct APIKeyCredential: Sendable, Codable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public let region: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
    }
}

public struct BasicCredential: Sendable, Codable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum Credential: Sendable {
    case oauth(OAuthCredential)
    case apiKey(APIKeyCredential)
    case basic(BasicCredential)
    case sshKey(privateKey: Data, passphrase: String?)
}

// MARK: - CredentialVault

public actor CredentialVault {
    public static let shared = CredentialVault()
    private let keychain = KeychainStore.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "CredentialVault")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - OAuth Credentials

    public func saveOAuthCredential(_ credential: OAuthCredential, providerID: String, accountID: String) async throws {
        let data = try encoder.encode(credential)
        try await keychain.saveSecret(
            data,
            service: KeychainStore.ServiceName.accessToken(
                providerID: providerID,
                accountID: accountID
            ),
            account: accountID
        )
    }

    public func loadOAuthCredential(providerID: String, accountID: String) async throws -> OAuthCredential? {
        guard let data = try await keychain.loadSecret(
            service: KeychainStore.ServiceName.accessToken(providerID: providerID, accountID: accountID),
            account: accountID
        ) else { return nil }
        return try decoder.decode(OAuthCredential.self, from: data)
    }

    public func deleteOAuthCredential(providerID: String, accountID: String) async throws {
        try await keychain.deleteSecret(
            service: KeychainStore.ServiceName.accessToken(providerID: providerID, accountID: accountID),
            account: accountID
        )
    }

    // MARK: - API Key Credentials

    public func saveAPIKeyCredential(
        _ credential: APIKeyCredential,
        providerID: String,
        accountID: String
    ) async throws {
        let data = try encoder.encode(credential)
        try await keychain.saveSecret(
            data,
            service: KeychainStore.ServiceName.apiKey(
                providerID: providerID,
                accountID: accountID
            ),
            account: accountID
        )
    }

    public func loadAPIKeyCredential(providerID: String, accountID: String) async throws -> APIKeyCredential? {
        guard let data = try await keychain.loadSecret(
            service: KeychainStore.ServiceName.apiKey(providerID: providerID, accountID: accountID),
            account: accountID
        ) else { return nil }
        return try decoder.decode(APIKeyCredential.self, from: data)
    }

    // MARK: - Basic Credentials

    public func saveBasicCredential(_ credential: BasicCredential, providerID: String, accountID: String) async throws {
        let data = try encoder.encode(credential)
        try await keychain.saveSecret(
            data,
            service: KeychainStore.ServiceName.sftpPassword(accountID: accountID),
            account: accountID
        )
    }

    public func loadBasicCredential(providerID: String, accountID: String) async throws -> BasicCredential? {
        guard let data = try await keychain.loadSecret(
            service: KeychainStore.ServiceName.sftpPassword(accountID: accountID),
            account: accountID
        ) else { return nil }
        return try decoder.decode(BasicCredential.self, from: data)
    }

    // MARK: - Full Account Deletion

    public func deleteAllCredentials(for account: CloudAccount) async throws {
        try await keychain.deleteAllItems(forAccount: account.id)
        logger.info("Deleted all credentials for account \(account.id)")
    }

    // MARK: - Biometric Authentication

    public func authenticateWithBiometrics(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let error { throw error }
            return false
        }
        return try await withCheckedThrowingContinuation { continuation in
            context
                .evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
        }
    }
}
