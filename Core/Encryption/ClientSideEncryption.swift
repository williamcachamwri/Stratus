import CryptoKit
import Foundation
import os.log

// MARK: - EncryptionHeader

// Prefix for every encrypted Stratus payload.  Payload bytes after this header
// are a sequence of independently authenticated AES-GCM chunk frames.

private let encryptionMagic: [UInt8] = [0x53, 0x54, 0x52, 0x53] // "STRS"
private let legacyEncryptionMagic: [UInt8] = [0x53, 0x54, 0x52, 0x45] // "STRE"
private let encryptionVersion: UInt8 = 1
private let aesGCMNonceLength = 12
private let aesGCMTagLength = 16
private let frameLengthByteCount = 4

public struct EncryptionHeader: Sendable {
    public let iv: Data // 12 bytes: file-level identifier for AAD domain separation
    public let wrappedFileKey: Data // 60 bytes: 12 nonce + 32 key ciphertext + 16 tag
    public let originalSize: Int64
    static let byteLength = 4 + 1 + 12 + 60 + 8

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
        let magic = Array(data[0 ..< 4])
        guard magic == encryptionMagic || magic == legacyEncryptionMagic else {
            throw EncryptionError.integrityCheckFailed
        }
        let version = data[4]
        guard version == encryptionVersion else { throw EncryptionError.unsupportedVersion(version) }
        let iv = data[5 ..< 17]
        let wrappedKey = data[17 ..< 77]
        let sizeBytes = data[77 ..< 85]
        let size = sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return EncryptionHeader(iv: Data(iv), wrappedFileKey: Data(wrappedKey), originalSize: size)
    }
}

// MARK: - ClientSideEncryption

public actor ClientSideEncryption {
    private let masterKey: SymmetricKey
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Encryption")
    private static let chunkSize = 1024 * 1024 // 1 MiB streaming encryption chunks

    public init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
    }

    // MARK: - Encrypt File

    public func encrypt(fileURL: URL, to outputURL: URL) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let originalSize = (attrs[.size] as? Int64) ?? 0
        let fileKey = SymmetricKey(size: .bits256)
        let fileIdentifier = try EncryptionKeyDerivation.secureRandomData(count: aesGCMNonceLength)
        let wrappedFileKey = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        let header = EncryptionHeader(iv: fileIdentifier, wrappedFileKey: wrappedFileKey, originalSize: originalSize)

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        try outputHandle.write(contentsOf: header.serialized())

        var chunkIndex = 0
        var bytesRead: Int64 = 0
        while true {
            guard let chunk = try inputHandle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            let frame = try Self.encryptFrame(
                plaintext: chunk,
                fileKey: fileKey,
                fileIdentifier: header.iv,
                chunkIndex: chunkIndex,
                originalSize: originalSize
            )
            try outputHandle.write(contentsOf: frame)
            bytesRead += Int64(chunk.count)
            chunkIndex += 1
        }

        logger.debug("Encrypted \(fileURL.lastPathComponent): \(bytesRead) plaintext bytes in \(chunkIndex) frames")
    }

    // MARK: - Decrypt File

    public func decrypt(encryptedURL: URL, to outputURL: URL) async throws {
        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? inputHandle.close() }

        guard let headerData = try inputHandle.read(upToCount: EncryptionHeader.byteLength) else {
            throw EncryptionError.decryptionFailed
        }
        let header = try EncryptionHeader.parse(from: headerData)
        let fileKey = try EncryptionKeyDerivation.unwrapKey(header.wrappedFileKey, with: masterKey)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        var chunkIndex = 0
        var bytesWritten: Int64 = 0
        while true {
            let lengthData = try inputHandle.read(upToCount: frameLengthByteCount) ?? Data()
            if lengthData.isEmpty { break }
            guard lengthData.count == frameLengthByteCount else { throw EncryptionError.decryptionFailed }
            guard let frame = try readFrameBody(lengthData: lengthData, from: inputHandle) else { break }
            let plaintext = try Self.decryptFrame(
                frame: frame,
                fileKey: fileKey,
                fileIdentifier: header.iv,
                chunkIndex: chunkIndex,
                originalSize: header.originalSize
            )
            try outputHandle.write(contentsOf: plaintext)
            bytesWritten += Int64(plaintext.count)
            chunkIndex += 1
        }

        guard bytesWritten == header.originalSize else {
            throw EncryptionError.integrityCheckFailed
        }
        logger
            .debug(
                "Decrypted \(encryptedURL.lastPathComponent): \(bytesWritten) plaintext bytes in \(chunkIndex) frames"
            )
    }

    // MARK: - In-memory Encrypt/Decrypt (for small payloads)

    public func encryptData(_ data: Data) throws -> Data {
        let fileKey = SymmetricKey(size: .bits256)
        let fileIdentifier = try EncryptionKeyDerivation.secureRandomData(count: aesGCMNonceLength)
        let wrappedFileKey = try EncryptionKeyDerivation.wrapKey(fileKey, with: masterKey)
        let header = EncryptionHeader(
            iv: fileIdentifier,
            wrappedFileKey: wrappedFileKey,
            originalSize: Int64(data.count)
        )
        var encrypted = header.serialized()
        try encrypted.append(Self.encryptFrame(
            plaintext: data,
            fileKey: fileKey,
            fileIdentifier: fileIdentifier,
            chunkIndex: 0,
            originalSize: Int64(data.count)
        ))
        return encrypted
    }

    public func decryptData(_ data: Data) throws -> Data {
        let header = try EncryptionHeader.parse(from: data)
        let fileKey = try EncryptionKeyDerivation.unwrapKey(header.wrappedFileKey, with: masterKey)
        var offset = EncryptionHeader.byteLength
        var chunkIndex = 0
        var plaintext = Data()

        while offset < data.count {
            guard data.count - offset >= frameLengthByteCount else { throw EncryptionError.decryptionFailed }
            let lengthData = data[offset ..< (offset + frameLengthByteCount)]
            offset += frameLengthByteCount
            let encryptedLength = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard encryptedLength >= aesGCMTagLength else { throw EncryptionError.decryptionFailed }
            guard data.count - offset >= aesGCMNonceLength + encryptedLength
            else { throw EncryptionError.decryptionFailed }
            let nonceData = data[offset ..< (offset + aesGCMNonceLength)]
            offset += aesGCMNonceLength
            let encryptedPayload = data[offset ..< (offset + encryptedLength)]
            offset += encryptedLength

            let frame = EncryptedFrame(nonce: Data(nonceData), encryptedPayload: Data(encryptedPayload))
            let chunk = try Self.decryptFrame(
                frame: frame,
                fileKey: fileKey,
                fileIdentifier: header.iv,
                chunkIndex: chunkIndex,
                originalSize: header.originalSize
            )
            plaintext.append(chunk)
            chunkIndex += 1
        }

        guard plaintext.count == header.originalSize else { throw EncryptionError.integrityCheckFailed }
        return plaintext
    }

    // MARK: - Frames

    private struct EncryptedFrame {
        let nonce: Data
        let encryptedPayload: Data // ciphertext + 16-byte auth tag
    }

    private static func encryptFrame(
        plaintext: Data,
        fileKey: SymmetricKey,
        fileIdentifier: Data,
        chunkIndex: Int,
        originalSize: Int64
    ) throws -> Data {
        let nonceData = try EncryptionKeyDerivation.secureRandomData(count: aesGCMNonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let aad = authenticatedData(fileIdentifier: fileIdentifier, chunkIndex: chunkIndex, originalSize: originalSize)
        let sealedBox = try AES.GCM.seal(plaintext, using: fileKey, nonce: nonce, authenticating: aad)
        let encryptedPayload = sealedBox.ciphertext + sealedBox.tag
        guard encryptedPayload.count >= aesGCMTagLength else { throw EncryptionError.encryptionFailed }
        guard encryptedPayload.count <= Int(UInt32.max) else { throw EncryptionError.encryptionFailed }

        var frame = Data()
        var length = UInt32(encryptedPayload.count).bigEndian
        frame.append(Data(bytes: &length, count: frameLengthByteCount))
        frame.append(nonceData)
        frame.append(encryptedPayload)
        return frame
    }

    private static func decryptFrame(
        frame: EncryptedFrame,
        fileKey: SymmetricKey,
        fileIdentifier: Data,
        chunkIndex: Int,
        originalSize: Int64
    ) throws -> Data {
        guard frame.nonce.count == aesGCMNonceLength else { throw EncryptionError.decryptionFailed }
        guard frame.encryptedPayload.count >= aesGCMTagLength else { throw EncryptionError.decryptionFailed }
        let ciphertext = frame.encryptedPayload.dropLast(aesGCMTagLength)
        let tag = frame.encryptedPayload.suffix(aesGCMTagLength)
        let aad = authenticatedData(fileIdentifier: fileIdentifier, chunkIndex: chunkIndex, originalSize: originalSize)
        let nonce = try AES.GCM.Nonce(data: frame.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: fileKey, authenticating: aad)
    }

    private static func authenticatedData(fileIdentifier: Data, chunkIndex: Int, originalSize: Int64) -> Data {
        var aad = Data("stratus.encrypted-chunk.v1".utf8)
        aad.append(fileIdentifier)
        var index = UInt64(chunkIndex).bigEndian
        aad.append(Data(bytes: &index, count: MemoryLayout<UInt64>.size))
        var size = originalSize.bigEndian
        aad.append(Data(bytes: &size, count: MemoryLayout<Int64>.size))
        return aad
    }

    private func readFrameBody(lengthData: Data, from inputHandle: FileHandle) throws -> EncryptedFrame? {
        let encryptedLength = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard encryptedLength >= aesGCMTagLength else { throw EncryptionError.decryptionFailed }
        guard let nonceData = try inputHandle.read(upToCount: aesGCMNonceLength),
              nonceData.count == aesGCMNonceLength
        else {
            throw EncryptionError.decryptionFailed
        }
        guard let encryptedPayload = try inputHandle.read(upToCount: encryptedLength),
              encryptedPayload.count == encryptedLength
        else {
            throw EncryptionError.decryptionFailed
        }
        return EncryptedFrame(nonce: nonceData, encryptedPayload: encryptedPayload)
    }
}
