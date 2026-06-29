import Foundation

// MARK: - Upload Task Priority

public enum TaskPriority: Int, Comparable, Sendable, Codable {
    case idle = 0
    case low = 25
    case normal = 50
    case high = 75
    case critical = 100

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Upload State Machine

public enum UploadState: Equatable, Sendable {
    case queued(priority: TaskPriority)
    case hashing(progress: Double)
    case deltaChecking
    case chunking
    case uploading(chunks: ChunkProgress)
    case verifying
    case assembling
    case completed(summary: UploadSummary)
    case paused(resumeToken: String?)
    case failed(error: UploadError, attempt: Int)
    case cancelled
    case skipped(reason: SkipReason)
}

public struct ChunkProgress: Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public let inFlight: Int
    public let failed: Int
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let currentSpeedBPS: Double
    public let estimatedSecondsRemaining: Double

    public var percentComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    public init(
        total: Int,
        completed: Int,
        inFlight: Int,
        failed: Int,
        bytesTransferred: Int64,
        totalBytes: Int64,
        currentSpeedBPS: Double,
        estimatedSecondsRemaining: Double
    ) {
        self.total = total
        self.completed = completed
        self.inFlight = inFlight
        self.failed = failed
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.currentSpeedBPS = currentSpeedBPS
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

public struct UploadSummary: Equatable, Sendable {
    public let fileSize: Int64
    public let bytesUploaded: Int64
    public let bytesSkippedByDelta: Int64
    public let durationSeconds: Double
    public let averageBPS: Double
    public let checksumVerified: Bool
    public let remoteItem: CloudFileItem

    public init(
        fileSize: Int64,
        bytesUploaded: Int64,
        bytesSkippedByDelta: Int64 = 0,
        durationSeconds: Double,
        averageBPS: Double,
        checksumVerified: Bool,
        remoteItem: CloudFileItem
    ) {
        self.fileSize = fileSize
        self.bytesUploaded = bytesUploaded
        self.bytesSkippedByDelta = bytesSkippedByDelta
        self.durationSeconds = durationSeconds
        self.averageBPS = averageBPS
        self.checksumVerified = checksumVerified
        self.remoteItem = remoteItem
    }
}

public enum SkipReason: Sendable, Equatable {
    case identicalChecksum
    case deltaNoChangedBlocks
    case olderThanRemote
}

public enum UploadError: Error, Sendable, Equatable {
    case fileNotFound(URL)
    case fileChanged(URL)
    case chunkExhausted(chunkNumber: Int, attempts: Int)
    case checksumMismatch(expected: String, actual: String)
    case providerError(String)
    case networkUnavailable
    case cancelled
    case quotaExceeded
    case authenticationFailed
    case unknown(String)
}

// MARK: - Upload Task

public final class UploadTask: @unchecked Sendable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationPath: CloudPath
    public let accountID: String
    public let providerID: String
    public let fileSize: Int64
    public let localChecksum: String
    public let priority: TaskPriority
    public let metadata: UploadMetadata
    public let createdAt: Date

    // State is protected by explicit locking via the actor that owns this task
    private(set) public var state: UploadState
    private(set) public var retryCount: Int = 0
    private(set) public var uploadID: String?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationPath: CloudPath,
        accountID: String,
        providerID: String,
        fileSize: Int64,
        localChecksum: String,
        priority: TaskPriority = .normal,
        metadata: UploadMetadata = UploadMetadata(),
        state: UploadState = .queued(priority: .normal),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationPath = destinationPath
        self.accountID = accountID
        self.providerID = providerID
        self.fileSize = fileSize
        self.localChecksum = localChecksum
        self.priority = priority
        self.metadata = metadata
        self.state = state
        self.createdAt = createdAt
    }

    public func transition(to newState: UploadState) {
        state = newState
    }

    public func setUploadID(_ id: String) {
        uploadID = id
    }

    public func incrementRetry() {
        retryCount += 1
    }
}

// MARK: - Upload Session (persisted form)

public struct UploadSession: Sendable, Codable {
    public let id: String
    public let fileBookmark: Data?
    public let fileURLString: String
    public let providerID: String
    public let accountID: String
    public let remotePath: String
    public var uploadID: String?
    public let fileSize: Int64
    public let fileChecksum: String
    public let chunkSize: Int
    public let totalChunks: Int
    public var completedChunks: [Int]
    public var etags: [Int: String]  // chunkNumber → ETag
    public var state: String
    public var retryCount: Int
    public var errorDescription: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        fileBookmark: Data? = nil,
        fileURLString: String,
        providerID: String,
        accountID: String,
        remotePath: String,
        uploadID: String? = nil,
        fileSize: Int64,
        fileChecksum: String,
        chunkSize: Int,
        totalChunks: Int,
        completedChunks: [Int] = [],
        etags: [Int: String] = [:],
        state: String = "uploading",
        retryCount: Int = 0,
        errorDescription: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fileBookmark = fileBookmark
        self.fileURLString = fileURLString
        self.providerID = providerID
        self.accountID = accountID
        self.remotePath = remotePath
        self.uploadID = uploadID
        self.fileSize = fileSize
        self.fileChecksum = fileChecksum
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.completedChunks = completedChunks
        self.etags = etags
        self.state = state
        self.retryCount = retryCount
        self.errorDescription = errorDescription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isComplete: Bool { completedChunks.count == totalChunks }
    public var remainingChunks: [Int] {
        let done = Set(completedChunks)
        return (0..<totalChunks).filter { !done.contains($0) }
    }
}
