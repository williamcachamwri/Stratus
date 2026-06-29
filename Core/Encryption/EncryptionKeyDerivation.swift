import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - Argon2id Key Derivation
// Uses CommonCrypto's PBKDF2-SHA256 as a safe substitute until a native Argon2 library ships.
// The KDF parameters are tuned for interactive use on macOS: ~100ms per derivation.

public struct EncryptionKeyDerivation: Sendable {
    private static let saltLength = 32
    private static let keyLength = 32  // AES-256
    // PBKDF2 iterations calibrated for ~100ms on an M1 at interactive login
    private static let pbkdf2Iterations: Int = 310_000

    // MARK: - Key Derivation

    public static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard salt.count == saltLength else {
            throw EncryptionError.invalidSaltLength(expected: saltLength, got: salt.count)
        }
        var derivedBytes = [UInt8](repeating: 0, count: keyLength)
        let passwordBytes = Array(password.utf8)

        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(pbkdf2Iterations),
                &derivedBytes, keyLength
            )
        }
        guard status == kCCSuccess else {
            throw EncryptionError.keyDerivationFailed(Int(status))
        }
        return SymmetricKey(data: Data(derivedBytes))
    }

    public static func generateSalt() throws -> Data {
        try secureRandomData(count: saltLength)
    }

    public static func secureRandomData(count: Int) throws -> Data {
        guard count >= 0 else { throw EncryptionError.invalidRandomByteCount(count) }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptionError.secureRandomFailed(Int(status))
        }
        return Data(bytes)
    }

    // MARK: - Key Wrapping (for storing file keys encrypted with the master key)

    public static func wrapKey(_ fileKey: SymmetricKey, with masterKey: SymmetricKey) throws -> Data {
        let fileKeyData = fileKey.withUnsafeBytes { Data($0) }
        let sealedBox = try AES.GCM.seal(fileKeyData, using: masterKey)
        guard let combined = sealedBox.combined else { throw EncryptionError.encryptionFailed }
        return combined
    }

    public static func unwrapKey(_ wrappedKey: Data, with masterKey: SymmetricKey) throws -> SymmetricKey {
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKey)
        let keyData = try AES.GCM.open(sealedBox, using: masterKey)
        return SymmetricKey(data: keyData)
    }
}

// MARK: - Encryption Error

public enum EncryptionError: Error, Sendable {
    case invalidSaltLength(expected: Int, got: Int)
    case keyDerivationFailed(Int)
    case secureRandomFailed(Int)
    case invalidRandomByteCount(Int)
    case unsupportedVersion(UInt8)
    case encryptionFailed
    case decryptionFailed
    case integrityCheckFailed
    case manifestNotFound
    case missingFileKey(String)
}
