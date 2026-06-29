import Foundation
import os.log

// MARK: - Segment

/// A single contiguous byte-range slice of a file to be downloaded independently.
private struct Segment: Sendable {
    let index: Int
    let range: ClosedRange<Int64>

    var length: Int64 { range.upperBound - range.lowerBound + 1 }
}

// MARK: - SegmentResult

private struct SegmentResult: Sendable {
    let index: Int
    let data: Data
}

// MARK: - ParallelRangeDownloaderConfiguration

public struct ParallelRangeDownloaderConfiguration: Sendable {
    /// Preferred segment size in bytes. The last segment may be smaller.
    public let segmentSize: Int64
    /// Maximum number of segments to download simultaneously.
    public let maxConcurrentSegments: Int
    /// Maximum number of retry attempts per segment before escalating to failure.
    public let maxSegmentRetries: Int
    /// Base delay for exponential back-off between retries (seconds).
    public let retryBaseDelay: TimeInterval

    public static let `default` = ParallelRangeDownloaderConfiguration(
        segmentSize: 8 * 1024 * 1024,   // 8 MiB per segment
        maxConcurrentSegments: 4,
        maxSegmentRetries: 3,
        retryBaseDelay: 0.5
    )

    public init(
        segmentSize: Int64 = 8 * 1024 * 1024,
        maxConcurrentSegments: Int = 4,
        maxSegmentRetries: Int = 3,
        retryBaseDelay: TimeInterval = 0.5
    ) {
        self.segmentSize = max(1, segmentSize)
        self.maxConcurrentSegments = max(1, maxConcurrentSegments)
        self.maxSegmentRetries = max(0, maxSegmentRetries)
        self.retryBaseDelay = retryBaseDelay
    }
}

// MARK: - ProgressUpdate (sent back to callers via AsyncStream)

public struct SegmentProgressUpdate: Sendable {
    public let segmentsCompleted: Int
    public let segmentsTotal: Int
    public let bytesReceived: Int64
    public let totalBytes: Int64
}

// MARK: - ParallelRangeDownloader

/// Downloads a file in parallel byte-range segments and reassembles them in
/// the correct order into a single contiguous Data or local file.
///
/// The actor serialises bookkeeping (segment registry, byte-count tracking)
/// while the heavy network I/O runs in concurrent child Tasks.
public actor ParallelRangeDownloader {

    // MARK: Dependencies

    private let provider: any CloudProvider
    private let configuration: ParallelRangeDownloaderConfiguration
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ParallelRangeDownloader")

    // MARK: Init

    public init(
        provider: some CloudProvider,
        configuration: ParallelRangeDownloaderConfiguration = .default
    ) {
        self.provider = provider
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Downloads `path` in parallel and returns the assembled `Data`.
    ///
    /// - Parameters:
    ///   - path: Remote path.
    ///   - fileSize: Known file size in bytes. Determines segment layout.
    ///   - account: The authenticated account to use.
    ///   - alreadyCompletedSegmentIndices: Pass previously completed segment
    ///     indices to skip them on resume.
    ///   - progressHandler: Closure called (on this actor's executor) after
    ///     each segment completes.
    /// - Returns: Assembled file data.
    public func download(
        path: CloudPath,
        fileSize: Int64,
        account: CloudAccount,
        alreadyCompletedSegmentIndices: Set<Int> = [],
        progressHandler: (@Sendable (SegmentProgressUpdate) -> Void)? = nil
    ) async throws(DownloadError) -> Data {
        guard fileSize > 0 else { return Data() }

        let segments = makeSegments(fileSize: fileSize)
        let totalSegments = segments.count

        // Buffer to hold each segment's data, indexed by segment.index.
        // Initialized to nil; filled in as segments complete.
        var buffer: [Data?] = Array(repeating: nil, count: totalSegments)
        var completedCount = alreadyCompletedSegmentIndices.count
        var bytesReceived: Int64 = 0

        // Account for bytes already downloaded on resume.
        for idx in alreadyCompletedSegmentIndices {
            if idx < segments.count {
                bytesReceived += segments[idx].length
                buffer[idx] = Data()  // placeholder; will not be re-downloaded
            }
        }

        let pending = segments.filter { !alreadyCompletedSegmentIndices.contains($0.index) }

        logger.debug("Starting download of \(path) — \(totalSegments) segments, \(pending.count) pending")

        // Bounded concurrency: process pending segments in windows of
        // `maxConcurrentSegments` using a TaskGroup.
        do {
            try await withThrowingTaskGroup(of: SegmentResult.self) { group in
                var pendingIterator = pending.makeIterator()
                var inFlight = 0

                // Seed the group with the initial window of tasks.
                while inFlight < configuration.maxConcurrentSegments,
                      let segment = pendingIterator.next() {
                    let seg = segment
                    group.addTask {
                        try await self.downloadSegment(seg, path: path, account: account)
                    }
                    inFlight += 1
                }

                // Collect results and refill the window.
                for try await result in group {
                    buffer[result.index] = result.data
                    completedCount += 1
                    bytesReceived += Int64(result.data.count)

                    progressHandler?(SegmentProgressUpdate(
                        segmentsCompleted: completedCount,
                        segmentsTotal: totalSegments,
                        bytesReceived: bytesReceived,
                        totalBytes: fileSize
                    ))

                    // Schedule the next pending segment to maintain the window size.
                    if let next = pendingIterator.next() {
                        let seg = next
                        group.addTask {
                            try await self.downloadSegment(seg, path: path, account: account)
                        }
                    }
                    inFlight -= 1
                }
            }
        } catch let err as DownloadError {
            throw err
        } catch {
            throw DownloadError.unknown(error.localizedDescription)
        }

        // Assemble in order.
        var assembled = Data()
        assembled.reserveCapacity(Int(fileSize))
        for (index, chunk) in buffer.enumerated() {
            guard let chunk else {
                throw DownloadError.segmentFailed(index: index, underlyingDescription: "Segment missing after all tasks completed")
            }
            assembled.append(chunk)
        }

        logger.debug("Download of \(path) complete — \(assembled.count) bytes assembled")
        return assembled
    }

    /// Downloads `path` in parallel and writes the result directly to a local
    /// file at `destination`. Preferred for large files to avoid holding the
    /// entire payload in memory.
    ///
    /// Returns the URL of the written file (same as `destination`).
    public func downloadToFile(
        path: CloudPath,
        fileSize: Int64,
        account: CloudAccount,
        destination: URL,
        alreadyCompletedSegmentIndices: Set<Int> = [],
        progressHandler: (@Sendable (SegmentProgressUpdate) -> Void)? = nil
    ) async throws(DownloadError) -> URL {
        let data = try await download(
            path: path,
            fileSize: fileSize,
            account: account,
            alreadyCompletedSegmentIndices: alreadyCompletedSegmentIndices,
            progressHandler: progressHandler
        )

        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw DownloadError.localIOError(error.localizedDescription)
        }

        return destination
    }

    // MARK: - Segment Helpers

    /// Divides `fileSize` bytes into segments respecting `configuration.segmentSize`.
    private func makeSegments(fileSize: Int64) -> [Segment] {
        guard fileSize > 0 else { return [] }

        var segments: [Segment] = []
        var offset: Int64 = 0
        var index = 0

        while offset < fileSize {
            let end = min(offset + configuration.segmentSize - 1, fileSize - 1)
            segments.append(Segment(index: index, range: offset...end))
            offset = end + 1
            index += 1
        }

        return segments
    }

    /// Downloads a single segment with exponential-back-off retry.
    private func downloadSegment(
        _ segment: Segment,
        path: CloudPath,
        account: CloudAccount
    ) async throws -> SegmentResult {
        var attempt = 0

        while true {
            do {
                let data = try await provider.downloadRange(
                    path: path,
                    range: segment.range,
                    account: account
                )
                return SegmentResult(index: segment.index, data: data)
            } catch let providerErr as ProviderError {
                // Non-retryable errors.
                if case .fileNotFound(let p) = providerErr {
                    throw DownloadError.fileNotFound(p)
                }
                attempt += 1
                if attempt > configuration.maxSegmentRetries {
                    throw DownloadError.segmentFailed(
                        index: segment.index,
                        underlyingDescription: providerErr.localizedDescription
                    )
                }
                let delay = configuration.retryBaseDelay * pow(2.0, Double(attempt - 1))
                logger.warning("Segment \(segment.index) attempt \(attempt) failed (\(providerErr.localizedDescription)); retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            } catch {
                attempt += 1
                if attempt > configuration.maxSegmentRetries {
                    throw DownloadError.segmentFailed(
                        index: segment.index,
                        underlyingDescription: error.localizedDescription
                    )
                }
                let delay = configuration.retryBaseDelay * pow(2.0, Double(attempt - 1))
                logger.warning("Segment \(segment.index) attempt \(attempt) failed (\(error.localizedDescription)); retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
}
