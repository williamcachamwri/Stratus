import Foundation

// MARK: - Download State Machine

//
// Valid transitions:
//   .queued      → .downloading, .cancelled
//   .downloading → .completed, .failed, .paused
//   .paused      → .downloading, .cancelled
//   .failed      → .queued (retry), .cancelled
//   .completed   → (terminal)
//   .cancelled   → (terminal)

public enum DownloadState: Equatable, Sendable {
    case queued(priority: DownloadPriority)
    case downloading(progress: DownloadProgress)
    case paused(resumeToken: DownloadResumeToken?)
    case completed(summary: DownloadSummary)
    case failed(error: DownloadError, attempt: Int)
    case cancelled
}

// MARK: - DownloadPriority

public enum DownloadPriority: Int, Comparable, Sendable, Codable {
    case background = 0
    case low = 25
    case normal = 50
    case high = 75
    case urgent = 100

    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - DownloadProgress

public struct DownloadProgress: Equatable, Sendable {
    /// Total file size in bytes; nil when the server did not supply Content-Length.
    public let totalBytes: Int64?
    public let receivedBytes: Int64
    public let segmentsTotal: Int
    public let segmentsCompleted: Int
    public let segmentsInFlight: Int
    /// Bytes per second averaged over the last measurement window.
    public let currentSpeedBPS: Double
    public let estimatedSecondsRemaining: Double?

    public var fractionCompleted: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(receivedBytes) / Double(total)
    }

    public init(
        totalBytes: Int64?,
        receivedBytes: Int64,
        segmentsTotal: Int,
        segmentsCompleted: Int,
        segmentsInFlight: Int,
        currentSpeedBPS: Double,
        estimatedSecondsRemaining: Double?
    ) {
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.segmentsTotal = segmentsTotal
        self.segmentsCompleted = segmentsCompleted
        self.segmentsInFlight = segmentsInFlight
        self.currentSpeedBPS = currentSpeedBPS
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

// MARK: - DownloadSummary

public struct DownloadSummary: Equatable, Sendable {
    public let totalBytes: Int64
    public let durationSeconds: Double
    public let averageBPS: Double
    public let segmentsUsed: Int
    public let localURL: URL
    public let checksumVerified: Bool

    public init(
        totalBytes: Int64,
        durationSeconds: Double,
        averageBPS: Double,
        segmentsUsed: Int,
        localURL: URL,
        checksumVerified: Bool
    ) {
        self.totalBytes = totalBytes
        self.durationSeconds = durationSeconds
        self.averageBPS = averageBPS
        self.segmentsUsed = segmentsUsed
        self.localURL = localURL
        self.checksumVerified = checksumVerified
    }
}

// MARK: - DownloadError

public enum DownloadError: Error, Sendable, Equatable {
    case fileNotFound(CloudPath)
    case networkUnavailable
    case segmentFailed(index: Int, underlyingDescription: String)
    case checksumMismatch(expected: String, actual: String)
    case insufficientDiskSpace(requiredBytes: Int64)
    case localIOError(String)
    case authenticationFailed
    case cancelled
    case providerError(String)
    case rangesNotSupported
    case maxRetriesExceeded(attempts: Int)
    case unknown(String)
}

// MARK: - DownloadResumeToken

/// Opaque token persisted across app restarts so a download can continue
/// from the last completed segment rather than restarting from byte 0.
public struct DownloadResumeToken: Equatable, Sendable, Codable {
    /// Identifies the persisted DownloadSession row in SQLite.
    public let sessionID: String
    /// Highest byte offset already written to the staging file.
    public let resumeOffset: Int64

    public init(sessionID: String, resumeOffset: Int64) {
        self.sessionID = sessionID
        self.resumeOffset = resumeOffset
    }
}

// MARK: - DownloadTask

/// Represents a single file download. Mutation is intentionally unguarded at
/// the class level because the DownloadEngine actor serialises all access.
public final class DownloadTask: @unchecked Sendable, Identifiable {
    // MARK: Immutable identity

    public let id: UUID
    /// Remote path of the file to download.
    public let sourcePath: CloudPath
    /// Where the finished file should land on disk.
    public let destinationURL: URL
    public let accountID: String
    public let providerID: String
    /// Expected file size in bytes; nil when unknown before the transfer starts.
    public let expectedSize: Int64?
    public let priority: DownloadPriority
    public let createdAt: Date

    // MARK: Mutable state (guarded by owning actor)

    public private(set) var state: DownloadState
    public private(set) var retryCount: Int = 0
    /// Set once the staging file URL is known (parallel downloader creates it).
    public private(set) var stagingURL: URL?

    // MARK: Init

    public init(
        id: UUID = UUID(),
        sourcePath: CloudPath,
        destinationURL: URL,
        accountID: String,
        providerID: String,
        expectedSize: Int64? = nil,
        priority: DownloadPriority = .normal,
        state: DownloadState? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationURL = destinationURL
        self.accountID = accountID
        self.providerID = providerID
        self.expectedSize = expectedSize
        self.priority = priority
        self.state = state ?? .queued(priority: priority)
        self.createdAt = createdAt
    }

    // MARK: State transitions

    /// Applies a state transition. Caller (always the DownloadEngine actor) is
    /// responsible for ensuring the transition is valid.
    public func transition(to newState: DownloadState) {
        state = newState
    }

    public func setStagingURL(_ url: URL) {
        stagingURL = url
    }

    public func incrementRetry() {
        retryCount += 1
    }

    // MARK: Derived helpers

    public var isTerminal: Bool {
        switch state {
        case .completed, .cancelled: true
        default: false
        }
    }

    public var resumeToken: DownloadResumeToken? {
        if case let .paused(token) = state { return token }
        return nil
    }
}
