import Foundation
import os.log

// MARK: - MultipartAssembler

// Thin wrapper over the provider's completeMultipartUpload / abortMultipartUpload.
// Centralises the completion and abort paths so ChunkEngine doesn't call the
// provider directly at the assembly step.

public enum MultipartAssemblerError: Error, Sendable {
    case completionFailed(String)
    case abortFailed(String)
}

public struct MultipartAssembler: Sendable {
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "MultipartAssembler")

    public init() {}

    // MARK: - Complete

    /// Commits all uploaded parts into a single remote file.
    /// Returns the assembled `CloudFileItem` reported by the provider.
    public func complete(
        uploadID: String,
        parts: [CompletedPart],
        provider: any CloudProvider,
        account: CloudAccount
    ) async throws -> CloudFileItem {
        logger.info("Completing multipart upload \(uploadID) with \(parts.count) parts")
        do {
            let item = try await provider.completeMultipartUpload(
                uploadID: uploadID,
                parts: parts,
                account: account
            )
            logger.info("Multipart upload \(uploadID) completed: \(item.id)")
            return item
        } catch {
            logger.error("Multipart complete failed for \(uploadID): \(error)")
            throw error
        }
    }

    // MARK: - Abort

    /// Aborts an in-progress multipart upload session, freeing any
    /// partially uploaded data on the provider's side.
    public func abort(
        uploadID: String,
        provider: any CloudProvider,
        account: CloudAccount
    ) async throws {
        logger.warning("Aborting multipart upload \(uploadID)")
        do {
            try await provider.abortMultipartUpload(uploadID: uploadID, account: account)
            logger.info("Multipart upload \(uploadID) aborted successfully")
        } catch {
            logger.error("Multipart abort failed for \(uploadID): \(error)")
            throw error
        }
    }
}
