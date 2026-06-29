import Foundation
import CryptoKit
import os.log

// MARK: - EncryptionHeader
// Stored as a prefix to each encrypted file: magic + version + IV + wrapped key

private let encryptionMagic: [UInt8] = [0x53, 0x54, 0x52, 0x45]  // "STRE"
private let encryptionVersion: UInt8 = 1

public struct EncryptionHeader: Sendable {
    public let iv: Data            // 12 bytes for AES-GCM nonce
    public let wrappedFileKey: Data // 60 bytes: 12 IV + 32 key ciphertext + 16 tag
    public let originalSize: Int64
    static let byteLength = 4 + 1 + 12 + 60 + 8  // magic + version + iv + wrapped key + size

    public func serialized() -> Data {
        var d = Data(encryptionMagic)
        d.append(encryptionVersion)
        d.append(iv)
        d.append(wrappedFileKey)
        var size = originalSize.bigEndian
        d.append(Data(bytes: &size, count: 8))
        return d
    }

    public static func parse(from data: Data) throws -> EncryptionHeader {
        guard data.count >= byteLength else { throw EncryptionError.decryptionFailed }
        let magic = Array(data[0..<4])
        guard magic == encryptionMagic else { throw EncryptionError.integrityCheckFailed }
        let iv = data[5..<17]
        let wrappedKey = data[17..<77]
        let sizeBytes = data[77..<85]
        let size = sizeBytes.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
        return EncryptionHeader(iv: Data(iv), wrappedFileKey: Data(wrappedKey), originalSize: size)
    }
}

// MARK: - ClientSideEncryption

public actor ClientSideEncryption {
    private let masterKey: SymmetricKey
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Encryption")
    private static let chunkSize = 64 * 1024  // 64KB streaming chunks

    public init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
    }

    // MARK: - Encrypt File

    public func encrypt(fileURL: URL, to outputURL: URL) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let originalSize = (attrs[.size] as? Int64) ?? 0

        let fileKey = SymmetricKey(size: .bits256)
        let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let nonce = try AES.GCM.Nonce(data: iv)
        let wrappedFileKey = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)

        let header = EncryptionHeader(iv: iv, wrappedFileKey: wrappedFileKey, originalSize: originalSize)
        let headerData = header.serialized()

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        try outputHandle.write(contentsOf: headerData)

        // Stream-encrypt in chunks
        var allPlaintext = Data()
        while true {
            let chunk = try inputHandle.read(upToCount: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            allPlaintext.append(chunk)
        }

        let sealedBox = try AES.GCM.seal(allPlaintext, using: fileKey, nonce: nonce)
        guard let ciphertext = sealedBox.combined else { throw EncryptionError.encryptionFailed }
        let encryptedPayload = ciphertext.dropFirst(12)  // Remove prepended nonce (already in header)
        try outputHandle.write(contentsOf: Data(encryptedPayload))

        logger.debug("Encrypted \(fileURL.lastPathComponent): \(allPlaintext.count) → \(encryptedPayload.count) bytes")
    }

    // MARK: - Decrypt File

    public func decrypt(encryptedURL: URL, to outputURL: URL) async throws {
        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? inputHandle.close() }

        let headerData = try inputHandle.read(upToCount: EncryptionHeader.byteLength)
        let header = try EncryptionHeader.parse(from: headerData)

        let fileKey = try EncryptionKeyDerivation.unwrapKey(header.wrappedFileKey, with: masterKey)
        let nonce = try AES.GCM.Nonce(data: header.iv)

        var ciphertextWithTag = nonce.withUnsafeBytes { Data($0) }
        while true {
            let chunk = try inputHandle.read(upToCount: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            ciphertextWithTag.append(chunk)
        }

        let sealedBox = try AES.GCM.SealedBox(combined: ciphertextWithTag)
        let plaintext = try AES.GCM.open(sealedBox, using: fileKey)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        try outputHandle.write(contentsOf: plaintext)

        logger.debug("Decrypted \(encryptedURL.lastPathComponent): \(ciphertextWithTag.count) → \(plaintext.count) bytes")
    }

    // MARK: - In-memory Encrypt/Decrypt (for small payloads)

    public func encryptData(_ data: Data) throws -> Data {
        let fileKey = SymmetricKey(size: .bits256)
        let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let nonce = try AES.GCM.Nonce(data: iv)
        let wrappedFileKey = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        let sealedBox = try AES.GCM.seal(data, using: fileKey, nonce: nonce)
        guard let combined = sealedBox.combined else { throw EncryptionError.encryptionFailed }
        let header = EncryptionHeader(iv: iv, wrappedFileKey: wrappedFileKey, originalSize: Int64(data.count))
        return header.serialized() + combined.dropFirst(12)
    }

    public func decryptData(_ data: Data) throws -> Data {
        let header = try EncryptionHeader.parse(from: data)
        let fileKey = try EncryptionKeyDerivation.unwrapKey(header.wrappedFileKey, with: masterKey)
        let nonce = try AES.GCM.Nonce(data: header.iv)
        let payload = data.dropFirst(EncryptionHeader.byteLength)
        var full = nonce.withUnsafeBytes { Data($0) }
        full.append(contentsOf: payload)
        let sealedBox = try AES.GCM.SealedBox(combined: full)
        return try AES.GCM.open(sealedBox, using: fileKey)
    }
}
