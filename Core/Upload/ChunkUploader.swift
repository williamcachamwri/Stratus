import Foundation
import os.log

// MARK: - ChunkUploader

// Wraps a single chunk upload attempt with exponential backoff retry logic.
// Used internally by ChunkEngine for per-chunk resilience.

public enum ChunkRetryError: Error, Sendable {
    case nonRetryableHTTPStatus(Int)
    case maxRetriesExceeded(attempts: Int, underlyingError: String)
    case cancelled
}

public struct ChunkUploader: Sendable {
    private static let maxAttempts = 5
    // Base backoff intervals in seconds: 1, 2, 4, 8, 16
    private static let backoffBase: [TimeInterval] = [1, 2, 4, 8, 16]
    private static let jitterFraction: Double = 0.25

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ChunkUploader")

    public init() {}

    // MARK: - Upload with Retry

    /// Attempts to upload `data` as chunk `chunkNumber` of `uploadID`.
    /// Retries up to 5 times with exponential backoff + ±25% jitter.
    /// Non-retriable HTTP statuses (400, 401, 403, 404, 409) surface immediately.
    public func upload(
        uploadID: String,
        chunkNumber: Int,
        data: Data,
        provider: any CloudProvider,
        account: CloudAccount
    ) async throws -> ChunkUploadResult {
        var lastError: (any Error)?

        for attempt in 0 ..< Self.maxAttempts {
            // Check cancellation before each attempt
            if Task.isCancelled {
                throw ChunkRetryError.cancelled
            }

            do {
                let result = try await provider.uploadChunk(
                    uploadID: uploadID,
                    chunkNumber: chunkNumber,
                    data: data,
                    account: account
                )
                if attempt > 0 {
                    logger.info("Chunk \(chunkNumber) of \(uploadID) succeeded after \(attempt + 1) attempts")
                }
                return result
            } catch {
                lastError = error

                // Check if non-retriable based on HTTP status embedded in ProviderError
                if isNonRetriable(error) {
                    logger.error("Chunk \(chunkNumber) failed with non-retriable error: \(error)")
                    if let providerError = error as? ProviderError,
                       case let .serverError(code, _) = providerError
                    {
                        throw ChunkRetryError.nonRetryableHTTPStatus(code)
                    }
                    if let httpError = error as? HTTPClientError,
                       case let .requestFailed(code, _) = httpError
                    {
                        throw ChunkRetryError.nonRetryableHTTPStatus(code)
                    }
                    throw ChunkRetryError.nonRetryableHTTPStatus(0)
                }

                // Last attempt — don't sleep, just fall through
                if attempt == Self.maxAttempts - 1 {
                    break
                }

                // Exponential backoff with ±25% jitter
                let base = Self.backoffBase[attempt]
                let jitter = base * Self.jitterFraction * Double.random(in: -1.0 ... 1.0)
                let delay = max(0, base + jitter)
                logger
                    .warning(
                        "Chunk \(chunkNumber) attempt \(attempt + 1) failed (\(error)). Retrying in \(String(format: "%.2f", delay))s"
                    )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw ChunkRetryError.maxRetriesExceeded(
            attempts: Self.maxAttempts,
            underlyingError: lastError.map { "\($0)" } ?? "unknown"
        )
    }

    // MARK: - Private Helpers

    private func isNonRetriable(_ error: any Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case let .serverError(code, _):
                // Non-retriable: 400, 401, 403, 404, 409
                return [400, 401, 403, 404, 409].contains(code)
            case .accessDenied:
                return true
            case .authenticationFailed:
                return true
            case .fileNotFound:
                return true
            case .quotaExceeded:
                return true
            case .unsupportedOperation:
                return true
            default:
                return false
            }
        }

        if let httpError = error as? HTTPClientError {
            switch httpError {
            case let .requestFailed(code, _):
                return [400, 401, 403, 404, 409].contains(code)
            case .cancelled:
                return true
            default:
                return false
            }
        }

        return false
    }
}
