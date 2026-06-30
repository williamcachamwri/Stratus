import Foundation

// MARK: - Per-file summary

public struct FileUploadSummary: Codable, Sendable {
    public let fileName: String
    public let fileSize: Int64
    public let bytesUploaded: Int64
    public let bytesSkippedByDelta: Int64
    public let durationSeconds: Double
    public let averageBPS: Double
    public let chunkCount: Int
    public let retriedChunks: Int
    public let checksumVerified: Bool

    public init(
        fileName: String,
        fileSize: Int64,
        bytesUploaded: Int64,
        bytesSkippedByDelta: Int64 = 0,
        durationSeconds: Double,
        averageBPS: Double,
        chunkCount: Int,
        retriedChunks: Int,
        checksumVerified: Bool
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.bytesUploaded = bytesUploaded
        self.bytesSkippedByDelta = bytesSkippedByDelta
        self.durationSeconds = durationSeconds
        self.averageBPS = averageBPS
        self.chunkCount = chunkCount
        self.retriedChunks = retriedChunks
        self.checksumVerified = checksumVerified
    }
}

// MARK: - Session-level metrics

public struct UploadSessionMetrics: Codable, Sendable {
    public let sessionID: UUID
    public let startTime: Date
    public var endTime: Date?

    // Throughput
    public var totalBytesUploaded: Int64 = 0
    public var effectiveBPS: Double = 0
    public var peakBPS: Double = 0
    public var averageBPS: Double = 0

    // Efficiency
    public var totalChunks: Int = 0
    public var failedChunks: Int = 0
    public var retriedChunks: Int = 0
    public var chunkSuccessRate: Double {
        totalChunks > 0 ? Double(totalChunks - failedChunks) / Double(totalChunks) : 1.0
    }

    /// Per-file breakdown
    public var fileSummaries: [FileUploadSummary] = []

    // Network quality
    public var averageRTTms: Double = 0
    public var packetLossEstimate: Double = 0
    public var congestionEvents: Int = 0

    // Delta efficiency
    public var bytesSkippedByDelta: Int64 = 0
    public var deltaEfficiencyPercent: Double {
        let total = totalBytesUploaded + bytesSkippedByDelta
        guard total > 0 else { return 0 }
        return Double(bytesSkippedByDelta) / Double(total) * 100
    }

    // Time breakdown
    public var timeHashingSeconds: Double = 0
    public var timeUploadingSeconds: Double = 0
    public var timeVerifyingSeconds: Double = 0
    public var timeWaitingOnProviderSeconds: Double = 0

    public init(sessionID: UUID = UUID(), startTime: Date = Date()) {
        self.sessionID = sessionID
        self.startTime = startTime
    }

    public var totalDurationSeconds: Double {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }
}

// MARK: - Metrics Collector

public actor UploadMetricsCollector {
    public static let shared = UploadMetricsCollector()
    private var sessions: [UUID: UploadSessionMetrics] = [:]

    private init() {}

    public func startSession() -> UUID {
        let metrics = UploadSessionMetrics()
        sessions[metrics.sessionID] = metrics
        return metrics.sessionID
    }

    public func recordBytes(_ bytes: Int64, sessionID: UUID) {
        sessions[sessionID]?.totalBytesUploaded += bytes
    }

    public func recordChunkRetry(sessionID: UUID) {
        sessions[sessionID]?.retriedChunks += 1
    }

    public func recordCongestionEvent(sessionID: UUID) {
        sessions[sessionID]?.congestionEvents += 1
    }

    public func recordFileSummary(_ summary: FileUploadSummary, sessionID: UUID) {
        sessions[sessionID]?.fileSummaries.append(summary)
        sessions[sessionID]?.totalChunks += summary.chunkCount
        sessions[sessionID]?.retriedChunks += summary.retriedChunks
        sessions[sessionID]?.bytesSkippedByDelta += summary.bytesSkippedByDelta
    }

    public func finalizeSession(_ sessionID: UUID, peakBPS: Double, averageBPS: Double) -> UploadSessionMetrics? {
        guard var metrics = sessions[sessionID] else { return nil }
        metrics.endTime = Date()
        metrics.peakBPS = peakBPS
        metrics.averageBPS = averageBPS
        let duration = metrics.totalDurationSeconds
        metrics.effectiveBPS = duration > 0 ? Double(metrics.totalBytesUploaded) / duration : 0
        sessions[sessionID] = metrics
        return metrics
    }

    public func session(_ id: UUID) -> UploadSessionMetrics? {
        sessions[id]
    }
}
