import Foundation
import Security
import os.log

// MARK: - Keychain Store

public actor KeychainStore {
    public static let shared = KeychainStore()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Keychain")
    private let accessGroup = "com.stratus.cloudmanager"

    private init() {}

    // MARK: - Internet Passwords (for OAuth tokens, API keys)

    public func saveToken(_ token: String, service: String, account: String) throws {
        let data = Data(token.utf8)
        try save(data: data, service: service, account: account, class: kSecClassInternetPassword)
    }

    public func loadToken(service: String, account: String) throws -> String? {
        guard let data = try load(service: service, account: account, class: kSecClassInternetPassword) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteToken(service: String, account: String) throws {
        try delete(service: service, account: account, class: kSecClassInternetPassword)
    }

    // MARK: - Generic Passwords (for API secrets, encryption keys)

    public func saveSecret(_ data: Data, service: String, account: String) throws {
        try save(data: data, service: service, account: account, class: kSecClassGenericPassword)
    }

    public func loadSecret(service: String, account: String) throws -> Data? {
        try load(service: service, account: account, class: kSecClassGenericPassword)
    }

    public func deleteSecret(service: String, account: String) throws {
        try delete(service: service, account: account, class: kSecClassGenericPassword)
    }

    // MARK: - Batch Operations

    public func deleteAllItems(forAccount accountID: String) throws {
        let classes: [CFString] = [kSecClassInternetPassword, kSecClassGenericPassword]
        for itemClass in classes {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrAccount as String: accountID,
                kSecAttrAccessGroup as String: accessGroup,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.deleteFailed(status: status)
            }
        }
    }

    // MARK: - Private Core Methods

    private func save(data: Data, service: String, account: String, class itemClass: CFString) throws {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            // Never accessible when device is locked; must be this device only
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try update first
        let updateQuery: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            logger.error("Keychain save failed: \(status)")
            throw KeychainError.saveFailed(status: status)
        }
    }

    private func load(service: String, account: String, class itemClass: CFString) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status: status)
        }
        return result as? Data
    }

    private func delete(service: String, account: String, class itemClass: CFString) throws {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

// MARK: - Keychain Error

public enum KeychainError: Error, Sendable {
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case invalidData
    case notFound
}

// MARK: - Service Name Helpers

public extension KeychainStore {
    enum ServiceName {
        static func accessToken(providerID: String, accountID: String) -> String {
            "com.stratus.oauth.access.\(providerID).\(accountID)"
        }
        static func refreshToken(providerID: String, accountID: String) -> String {
            "com.stratus.oauth.refresh.\(providerID).\(accountID)"
        }
        static func apiKey(providerID: String, accountID: String) -> String {
            "com.stratus.apikey.\(providerID).\(accountID)"
        }
        static func encryptionKey(vaultID: String) -> String {
            "com.stratus.vault.key.\(vaultID)"
        }
        static func sftpPassword(accountID: String) -> String {
            "com.stratus.sftp.password.\(accountID)"
        }
    }
}
