import Foundation
import CryptoKit

// MARK: - EncryptionManifest
// JSON-serializable manifest stored alongside an encrypted file (or in a sidecar).
// Maps original filenames to their encryption metadata.

public struct EncryptionManifest: Codable, Sendable {
    public var version: Int = 1
    public var entries: [String: ManifestEntry]
    public var createdAt: Date
    public var updatedAt: Date

    public struct ManifestEntry: Codable, Sendable {
        public let originalName: String
        public let encryptedName: String
        public let originalSize: Int64
        public let encryptedSize: Int64
        public let contentType: String?
        public let originalChecksum: String  // SHA-256 hex of plaintext
        public let encryptedAt: Date
    }

    public init() {
        entries = [:]
        createdAt = Date()
        updatedAt = Date()
    }

    public mutating func add(entry: ManifestEntry) {
        entries[entry.originalName] = entry
        updatedAt = Date()
    }

    public mutating func remove(originalName: String) {
        entries.removeValue(forKey: originalName)
        updatedAt = Date()
    }

    public func encryptedName(for originalName: String) -> String? {
        entries[originalName]?.encryptedName
    }

    public func originalName(for encryptedName: String) -> String? {
        entries.values.first { $0.encryptedName == encryptedName }?.originalName
    }

    // Sidecar filename for a given remote path
    public static func sidecarName(for remotePath: String) -> String {
        ".stratus_enc_manifest"
    }

    // Serializes to JSON, encrypted by the provided actor
    public func serializedJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func from(json: Data) throws -> EncryptionManifest {
        try JSONDecoder().decode(EncryptionManifest.self, from: json)
    }
}
