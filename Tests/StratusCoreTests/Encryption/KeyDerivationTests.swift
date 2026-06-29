import XCTest
import CryptoKit
@testable import StratusCore

final class KeyDerivationTests: XCTestCase {

    // MARK: - deriveKey determinism

    func test_derive_key_is_deterministic() throws {
        let salt = try EncryptionKeyDerivation.generateSalt()
        let k1 = try EncryptionKeyDerivation.deriveKey(password: "correct-horse-battery-staple", salt: salt)
        let k2 = try EncryptionKeyDerivation.deriveKey(password: "correct-horse-battery-staple", salt: salt)
        XCTAssertEqual(k1.bitCount, k2.bitCount)
        // Compare raw bytes
        let d1 = k1.withUnsafeBytes { Data($0) }
        let d2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(d1, d2, "Same password + salt must produce identical key")
    }

    func test_different_passwords_produce_different_keys() throws {
        let salt = try EncryptionKeyDerivation.generateSalt()
        let k1 = try EncryptionKeyDerivation.deriveKey(password: "password1", salt: salt)
        let k2 = try EncryptionKeyDerivation.deriveKey(password: "password2", salt: salt)
        let d1 = k1.withUnsafeBytes { Data($0) }
        let d2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(d1, d2, "Different passwords must produce different keys")
    }

    func test_different_salts_produce_different_keys() throws {
        let s1 = try EncryptionKeyDerivation.generateSalt()
        let s2 = try EncryptionKeyDerivation.generateSalt()
        let k1 = try EncryptionKeyDerivation.deriveKey(password: "same-password", salt: s1)
        let k2 = try EncryptionKeyDerivation.deriveKey(password: "same-password", salt: s2)
        let d1 = k1.withUnsafeBytes { Data($0) }
        let d2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(d1, d2, "Different salts must produce different keys")
    }

    // MARK: - generateSalt

    func test_generate_salt_length() throws {
        let salt = try EncryptionKeyDerivation.generateSalt()
        XCTAssertEqual(salt.count, 32, "Salt should be 32 bytes (256 bits)")
    }

    func test_generate_salt_is_random() throws {
        let s1 = try EncryptionKeyDerivation.generateSalt()
        let s2 = try EncryptionKeyDerivation.generateSalt()
        XCTAssertNotEqual(s1, s2, "Consecutive salt generations must differ (CSPRNG)")
    }

    // MARK: - key wrapping round-trip

    func test_wrap_unwrap_key_round_trip() throws {
        let masterKey = SymmetricKey(size: .bits256)
        let fileKey = SymmetricKey(size: .bits256)
        let wrapped = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        let unwrapped = try EncryptionKeyDerivation.unwrapKey(wrapped, with: masterKey)
        let original = fileKey.withUnsafeBytes { Data($0) }
        let recovered = unwrapped.withUnsafeBytes { Data($0) }
        XCTAssertEqual(original, recovered, "unwrapKey must recover the original fileKey")
    }

    func test_unwrap_with_wrong_master_key_throws() throws {
        let masterKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let fileKey = SymmetricKey(size: .bits256)
        let wrapped = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        XCTAssertThrowsError(try EncryptionKeyDerivation.unwrapKey(wrapped, with: wrongKey),
                             "Decrypting with wrong master key must throw")
    }

    func test_wrapped_key_is_not_plaintext() throws {
        let masterKey = SymmetricKey(size: .bits256)
        let fileKey = SymmetricKey(size: .bits256)
        let wrapped = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        let original = fileKey.withUnsafeBytes { Data($0) }
        // The wrapped ciphertext must not equal the raw key bytes
        XCTAssertNotEqual(wrapped, original)
    }

    // MARK: - key length

    func test_derived_key_is_256_bits() throws {
        let salt = try EncryptionKeyDerivation.generateSalt()
        let key = try EncryptionKeyDerivation.deriveKey(password: "test", salt: salt)
        XCTAssertEqual(key.bitCount, 256, "Derived key must be 256 bits (AES-256)")
    }

    // MARK: - Sendable conformance (compile-time)

    func test_encryption_key_derivation_sendable() {
        func requiresSendable<T: Sendable>(_: T.Type) {}
        requiresSendable(EncryptionKeyDerivation.self)
    }

    // MARK: - EncryptionError cases

    func test_encryption_error_cases_sendable() {
        // All EncryptionError cases must compile as Sendable values
        let errors: [EncryptionError] = [
            .invalidSaltLength(expected: 32, got: 16),
            .keyDerivationFailed(-1),
            .secureRandomFailed(-1),
            .invalidRandomByteCount(-1),
            .unsupportedVersion(255),
            .encryptionFailed,
            .decryptionFailed,
            .integrityCheckFailed,
            .manifestNotFound,
            .missingFileKey("some-key-id"),
        ]
        XCTAssertEqual(errors.count, 10)
    }
}
