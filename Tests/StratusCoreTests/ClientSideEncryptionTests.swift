import XCTest
import CryptoKit
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
        XCTAssertEqual(Array(header), [0x53, 0x54, 0x52, 0x45])  // "STRE"
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

    func test_inMemoryEncryptDecrypt() throws {
        let original = Data("in-memory test data 1234567890".utf8)
        let encrypted = try encryption.encryptData(original)
        let decrypted = try encryption.decryptData(encrypted)
        XCTAssertEqual(original, decrypted)
    }

    func test_largeFileRoundTrip() async throws {
        let size = 4 * 1024 * 1024  // 4MB
        let original = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        let plainURL = tempDir.appendingPathComponent("large.bin")
        let encURL = tempDir.appendingPathComponent("large.stre")
        let decURL = tempDir.appendingPathComponent("large_dec.bin")
        try original.write(to: plainURL)
        try await encryption.encrypt(fileURL: plainURL, to: encURL)
        try await encryption.decrypt(encryptedURL: encURL, to: decURL)
        let decrypted = try Data(contentsOf: decURL)
        XCTAssertEqual(original, decrypted)
    }
}
