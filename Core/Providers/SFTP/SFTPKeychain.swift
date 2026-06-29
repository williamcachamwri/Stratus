import Foundation
import os.log

// MARK: - SFTPKeychain
// Stores SFTP credentials (passwords and private keys) securely in the system Keychain.
// Delegates all raw Keychain access to KeychainStore — no SecItem calls here.

public actor SFTPKeychain {

    public static let shared = SFTPKeychain()

    private let keychain = KeychainStore.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SFTPKeychain")

    private init() {}

    // MARK: - Save

    /// Persists `credentials` for the given `host` + `username` pair.
    /// Overwrites any previously stored credentials for the same key.
    public func save(
        credentials: SFTPCredentials,
        for host: String,
        username: String
    ) async throws {
        if let password = credentials.password {
            try await keychain.saveToken(
                password,
                service: passwordService(host: host, username: username),
                account: username
            )
            logger.info("Saved SFTP password for \(username)@\(host)")
        }

        if let privateKey = credentials.privateKey {
            try await keychain.saveToken(
                privateKey,
                service: privateKeyService(host: host, username: username),
                account: username
            )
            logger.info("Saved SFTP private key for \(username)@\(host)")
        }
    }

    // MARK: - Load

    /// Returns the stored credentials for `host` + `username`, or `nil` if none exist.
    public func load(
        for host: String,
        username: String
    ) async throws -> SFTPCredentials? {
        let password = try await keychain.loadToken(
            service: passwordService(host: host, username: username),
            account: username
        )
        let privateKey = try await keychain.loadToken(
            service: privateKeyService(host: host, username: username),
            account: username
        )

        guard password != nil || privateKey != nil else {
            logger.debug("No SFTP credentials found for \(username)@\(host)")
            return nil
        }

        logger.debug("Loaded SFTP credentials for \(username)@\(host)")
        return SFTPCredentials(password: password, privateKey: privateKey)
    }

    // MARK: - Delete

    /// Removes all stored credentials (password and private key) for `host` + `username`.
    public func delete(
        for host: String,
        username: String
    ) async throws {
        // Delete password entry (ignore "not found" — it may not exist)
        do {
            try await keychain.deleteToken(
                service: passwordService(host: host, username: username),
                account: username
            )
        } catch KeychainError.deleteFailed(let status) where status == -25300 /* errSecItemNotFound */ {
            // Nothing to delete — not an error
        }

        // Delete private key entry
        do {
            try await keychain.deleteToken(
                service: privateKeyService(host: host, username: username),
                account: username
            )
        } catch KeychainError.deleteFailed(let status) where status == -25300 /* errSecItemNotFound */ {
            // Nothing to delete — not an error
        }

        logger.info("Deleted SFTP credentials for \(username)@\(host)")
    }

    // MARK: - Private Helpers

    private func passwordService(host: String, username: String) -> String {
        "com.stratus.sftp.password.\(host).\(username)"
    }

    private func privateKeyService(host: String, username: String) -> String {
        "com.stratus.sftp.privatekey.\(host).\(username)"
    }
}
