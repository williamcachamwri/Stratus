import CryptoKit
import XCTest
@testable import StratusCore

final class ClientSideEncryptionTests: XCTestCase {
    private var tempDir: URL!
    private var masterKey: SymmetricKey!
    private var encryption: ClientSideEncryption!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        masterKey = SymmetricKey(size: .bits256)
        encryption = ClientSideEncryption(masterKey: masterKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_encryptDecryptRoundTrip() async throws {
        let original = Data("Hello, Stratus encryption!".utf8)
        let plainURL = tempDir.appendingPathComponent("plain.txt")
        let encURL = tempDir.appendingPathComponent("enc.stre")
        let decURL = tempDir.appendingPathComponent("dec.txt")
        try original.write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        try await encryption.decrypt(encryptedURL: encURL, to: decURL)
        let decrypted = try Data(contentsOf: decURL)
        XCTAssertEqual(original, decrypted)
    }

    func test_encryptedFileIsDifferentFromOriginal() async throws {
        let original = Data(repeating: 0xAA, count: 1024)
        let plainURL = tempDir.appendingPathComponent("plain2.bin")
        let encURL = tempDir.appendingPathComponent("enc2.stre")
        try original.write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        let ciphertext = try Data(contentsOf: encURL)
        XCTAssertNotEqual(original, ciphertext)
    }

    func test_encryptedFileHasCorrectMagicBytes() async throws {
        let plainURL = tempDir.appendingPathComponent("magic.bin")
        let encURL = tempDir.appendingPathComponent("magic.stre")
        try Data("test".utf8).write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        let header = try Data(contentsOf: encURL).prefix(4)
        XCTAssertEqual(Array(header), [0x53, 0x54, 0x52, 0x53]) // "STRS"
    }

    func test_wrongKeyFailsDecryption() async throws {
        let original = Data("secret data".utf8)
        let plainURL = tempDir.appendingPathComponent("plain3.txt")
        let encURL = tempDir.appendingPathComponent("enc3.stre")
        let decURL = tempDir.appendingPathComponent("dec3.txt")
        try original.write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)

        let wrongKey = SymmetricKey(size: .bits256)
        let wrongEnc = ClientSideEncryption(masterKey: wrongKey)
        do {
            try await wrongEnc.decrypt(encryptedURL: encURL, to: decURL)
            XCTFail("Should have thrown on wrong key")
        } catch {
            // Expected
        }
    }

    func test_inMemoryEncryptDecrypt() async throws {
        let original = Data("in-memory test data 1234567890".utf8)
        let encrypted = try await encryption.encryptData(original)
        let decrypted = try await encryption.decryptData(encrypted)
        XCTAssertEqual(original, decrypted)
    }

    func test_largeFileRoundTrip() async throws {
        let size = 4 * 1024 * 1024 // 4MB
        let original = Data((0 ..< size).map { _ in UInt8.random(in: 0 ... 255) })
        let plainURL = tempDir.appendingPathComponent("large.bin")
        let encURL = tempDir.appendingPathComponent("large.stre")
        let decURL = tempDir.appendingPathComponent("large_dec.bin")
        try original.write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        try await encryption.decrypt(encryptedURL: encURL, to: decURL)
        let decrypted = try Data(contentsOf: decURL)
        XCTAssertEqual(original, decrypted)
    }

    func test_largeFileUsesMultipleAuthenticatedFrames() async throws {
        let size = 3 * 1024 * 1024 + 17
        let original = Data(repeating: 0x42, count: size)
        let plainURL = tempDir.appendingPathComponent("multi-frame.bin")
        let encURL = tempDir.appendingPathComponent("multi-frame.strs")
        let decURL = tempDir.appendingPathComponent("multi-frame-dec.bin")
        try original.write(to: plainURL)

        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        let encrypted = try Data(contentsOf: encURL)

        var offset = EncryptionHeader.byteLength
        var frameCount = 0
        while offset < encrypted.count {
            XCTAssertGreaterThanOrEqual(encrypted.count - offset, 4)
            let length = Int(encrypted[offset ..< (offset + 4)]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            offset += 4 + 12 + length
            frameCount += 1
        }

        XCTAssertGreaterThan(frameCount, 1, "Large encrypted files must be streamed into independent frames")
        XCTAssertEqual(offset, encrypted.count)

        try await encryption.decrypt(encryptedURL: encURL, to: decURL)
        XCTAssertEqual(try Data(contentsOf: decURL), original)
    }

    func test_bitflipInCiphertext_causesDecryptionFailure() async throws {
        // DoD: bitflip in ciphertext → AES-GCM auth failure, not silent corruption
        let original = Data("critical data that must not be silently corrupted".utf8)
        let encrypted = try await encryption.encryptData(original)
        var corrupted = encrypted
        corrupted[EncryptionHeader.byteLength] ^= 0xFF // flip first ciphertext byte
        do {
            _ = try await encryption.decryptData(corrupted)
            XCTFail("AES-GCM authentication must detect ciphertext corruption")
        } catch {
            // Expected: auth tag mismatch → decryptionFailed
        }
    }

    func test_encryptData_differentCiphertextEachCall() async throws {
        let data = Data("same plaintext same plaintext".utf8)
        let enc1 = try await encryption.encryptData(data)
        let enc2 = try await encryption.encryptData(data)
        XCTAssertNotEqual(enc1, enc2, "Each encryption must use a fresh random IV")
    }

    func test_encryptDecrypt_emptyData() async throws {
        let empty = Data()
        let encrypted = try await encryption.encryptData(empty)
        let decrypted = try await encryption.decryptData(encrypted)
        XCTAssertEqual(decrypted, empty, "Empty data must survive encrypt/decrypt round trip")
    }

    func test_headerParsing_wrongMagic_throwsIntegrityError() throws {
        var badHeader = Data(count: EncryptionHeader.byteLength)
        badHeader[0] = 0xFF // wrong magic (correct is 0x53 "S")
        do {
            _ = try EncryptionHeader.parse(from: badHeader)
            XCTFail("Wrong magic bytes must throw integrityCheckFailed")
        } catch EncryptionError.integrityCheckFailed {
            // Expected
        } catch {
            XCTFail("Expected integrityCheckFailed, got: \(error)")
        }
    }
}
