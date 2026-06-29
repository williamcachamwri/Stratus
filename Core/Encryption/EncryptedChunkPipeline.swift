import Foundation
import os.log

// MARK: - ProcessedChunk

/// The output of one pipeline stage: raw data has been checksummed,
/// encrypted, and the encrypted copy checksummed again.
public struct ProcessedChunk: Sendable {
    /// AES-GCM framed ciphertext ready for upload.
    public let encryptedData: Data

    /// SHA-256 hex digest of the *plaintext* bytes — stored in encrypted
    /// manifests for post-download verification.
    public let plaintextChecksum: String

    /// SHA-256 hex digest of `encryptedData` — this is the checksum the upload
    /// layer must compare with the provider response because providers only see
    /// ciphertext.
    public let encryptedChecksum: String

    /// Zero-based index of this chunk within its parent file.
    public let chunkIndex: Int
}

// MARK: - EncryptedChunkPipeline

/// Processes raw file chunks through:
/// 1. plaintext SHA-256,
/// 2. AES-256-GCM framed encryption,
/// 3. ciphertext SHA-256.
///
/// This implementation never writes plaintext temp files.  The caller should
/// drive multiple invocations with a `TaskGroup` when it wants encryption of
/// chunk N to overlap with upload of chunk N-1.
public actor EncryptedChunkPipeline {

    // MARK: - Dependencies

    private let encryption: ClientSideEncryption
    private let checksumEngine: ChecksumEngine
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "EncryptedChunkPipeline")

    // MARK: - Init

    public init(encryption: ClientSideEncryption, checksumEngine: ChecksumEngine) {
        self.encryption = encryption
        self.checksumEngine = checksumEngine
    }

    // MARK: - Process a chunk

    public func processChunk(
        data: Data,
        chunkIndex: Int,
        fileID: String
    ) async throws -> ProcessedChunk {
        let plaintextChecksum = await checksumEngine.sha256(of: data)
        let encryptedData = try await encryption.encryptData(data)
        let encryptedChecksum = await checksumEngine.sha256(of: encryptedData)

        logger.debug(
            "Encrypted chunk \(chunkIndex, privacy: .public) for file \(fileID, privacy: .private): plaintextSHA256=\(plaintextChecksum, privacy: .public) encryptedSHA256=\(encryptedChecksum, privacy: .public)"
        )

        return ProcessedChunk(
            encryptedData: encryptedData,
            plaintextChecksum: plaintextChecksum,
            encryptedChecksum: encryptedChecksum,
            chunkIndex: chunkIndex
        )
    }
}
