import Foundation
import os.log

// MARK: - ProcessedChunk

/// The output of one pipeline stage: raw data has been checksummed,
/// encrypted, and the encrypted copy checksummed again.
public struct ProcessedChunk: Sendable {
    /// AES-GCM ciphertext (including the prepended nonce and GCM tag) ready
    /// for upload.
    public let encryptedData: Data

    /// SHA-256 hex digest of the *plaintext* bytes — used for integrity
    /// verification after decryption.
    public let plaintextChecksum: String

    /// SHA-256 hex digest of `encryptedData` — lets the upload layer confirm
    /// the wire transfer was not corrupted without decrypting.
    public let encryptedChecksum: String

    /// Zero-based index of this chunk within its parent file.
    public let chunkIndex: Int
}

// MARK: - ChunkPipelineError

public enum ChunkPipelineError: Error, Sendable {
    /// The temp file required for encryption could not be written.
    case tempWriteFailed(chunkIndex: Int, underlying: any Error)
    /// `ClientSideEncryption.encrypt` returned but the output file is missing.
    case encryptedFileNotFound(chunkIndex: Int, url: URL)
    /// The encrypted output could not be read back into memory.
    case encryptedReadFailed(chunkIndex: Int, underlying: any Error)
}

// MARK: - EncryptedChunkPipeline

/// Processes raw file chunks through a three-stage pipeline:
///
///  1. **Checksum** — compute SHA-256 of plaintext via `ChecksumEngine`.
///  2. **Encrypt** — AES-GCM via `ClientSideEncryption`.
///  3. **Checksum** — compute SHA-256 of ciphertext via `ChecksumEngine`.
///
/// The pipeline supports pipelined parallelism: the *caller* is expected to
/// drive chunks with `async let` or a `TaskGroup` so that chunk N is being
/// encrypted while chunk N-1 is being uploaded.  Each call to
/// `processChunk(data:chunkIndex:fileID:)` is self-contained and safe to
/// call concurrently from multiple tasks.
///
/// Temp files are written to a per-`fileID` subdirectory of the system temp
/// directory and removed immediately after the encrypted bytes have been
/// read back into memory.
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

    /// Checksums, encrypts, and re-checksums `data`, returning a
    /// `ProcessedChunk` ready for upload.
    ///
    /// The method is `async` so that:
    /// - Multiple chunks can be dispatched concurrently from a `TaskGroup`.
    /// - While one chunk is encrypting (CPU-bound, inside the actor), the
    ///   previous chunk's upload (I/O-bound, outside the actor) continues on
    ///   the cooperative thread pool.
    ///
    /// - Parameters:
    ///   - data:       Raw plaintext bytes for this chunk.
    ///   - chunkIndex: Zero-based position of this chunk in the file.
    ///   - fileID:     Stable identifier for the parent file; used to
    ///                 namespace temp files so concurrent uploads do not
    ///                 collide.
    public func processChunk(
        data: Data,
        chunkIndex: Int,
        fileID: String
    ) async throws -> ProcessedChunk {

        // ── Stage 1: Plaintext checksum ──────────────────────────────────────
        let plaintextChecksum = await checksumEngine.sha256(of: data)
        logger.debug("Chunk \(chunkIndex) plaintext SHA-256: \(plaintextChecksum, privacy: .public)")

        // ── Stage 2: Encrypt ─────────────────────────────────────────────────
        // Write plaintext to a temp file so ClientSideEncryption can stream it.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stratus_pipeline/\(fileID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let plaintextURL = tempDir.appendingPathComponent("chunk_\(chunkIndex).plain")
        let encryptedURL = tempDir.appendingPathComponent("chunk_\(chunkIndex).enc")

        do {
            try data.write(to: plaintextURL, options: .atomic)
        } catch {
            throw ChunkPipelineError.tempWriteFailed(chunkIndex: chunkIndex, underlying: error)
        }

        defer {
            // Best-effort cleanup of both temp files regardless of outcome.
            try? FileManager.default.removeItem(at: plaintextURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }

        try await encryption.encrypt(fileURL: plaintextURL, to: encryptedURL)

        guard FileManager.default.fileExists(atPath: encryptedURL.path) else {
            throw ChunkPipelineError.encryptedFileNotFound(chunkIndex: chunkIndex, url: encryptedURL)
        }

        // ── Stage 3: Read back ciphertext + compute encrypted checksum ────────
        let encryptedData: Data
        do {
            encryptedData = try Data(contentsOf: encryptedURL)
        } catch {
            throw ChunkPipelineError.encryptedReadFailed(chunkIndex: chunkIndex, underlying: error)
        }

        let encryptedChecksum = await checksumEngine.sha256(of: encryptedData)
        logger.debug("Chunk \(chunkIndex) encrypted SHA-256: \(encryptedChecksum, privacy: .public)")

        return ProcessedChunk(
            encryptedData: encryptedData,
            plaintextChecksum: plaintextChecksum,
            encryptedChecksum: encryptedChecksum,
            chunkIndex: chunkIndex
        )
    }
}
