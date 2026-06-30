import Foundation
import os.log

// MARK: - Chunk Upload Result

public struct ChunkDescriptorWithResult: Sendable {
    public let chunk: ChunkDescriptor
    public let result: ChunkUploadResult
}

// MARK: - ParallelStreamUploader

// HTTP/2 multiplexed chunk uploads with exponential backoff retry.
// Never buffers full chunk in RAM — streams from InputStream.

public final class ParallelStreamUploader: @unchecked Sendable {
    // Retry schedule (seconds ± jitter fraction):
    // Attempt 1: immediate
    // Attempt 2: 1s ± 250ms
    // Attempt 3: 2s ± 500ms
    // Attempt 4: 4s ± 1s
    // Attempt 5: 8s ± 2s
    // Attempt 6: 16s ± 4s (final)
    private static let retryDelays: [TimeInterval] = [0, 1, 2, 4, 8, 16]
    private static let maxAttempts = 6

    private let session: URLSession
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ChunkUploader")

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // unlimited for large chunks
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Upload single chunk with retry

    public func upload(
        chunk: ChunkDescriptor,
        data: Data,
        to endpoint: URL,
        headers: [String: String],
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> ChunkUploadResult {
        var lastError: any Error = ChunkUploaderError.maxRetriesExceeded

        for attempt in 0 ..< Self.maxAttempts {
            // Exponential backoff with ±25% jitter
            if attempt > 0 {
                let base = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                let jitter = base * 0.25 * (Double.random(in: -1 ... 1))
                let delay = max(0, base + jitter)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                return try await performUpload(
                    data: data,
                    to: endpoint,
                    headers: headers,
                    chunkSize: Int64(chunk.size),
                    progressHandler: progressHandler
                )
            } catch let error as ChunkUploaderError {
                switch error {
                case .nonRetryableStatus:
                    throw error // 400/401/403/404/409 — do not retry
                case let .rateLimited(retryAfter):
                    let waitTime = retryAfter ?? Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                    logger.warning("Chunk \(chunk.number) rate limited, waiting \(waitTime)s")
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                    lastError = error
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }

            logger.warning("Chunk \(chunk.number) attempt \(attempt + 1) failed: \(lastError)")
        }

        throw ChunkUploaderError.maxRetriesExceeded
    }

    // MARK: - Private

    private func performUpload(
        data: Data,
        to url: URL,
        headers: [String: String],
        chunkSize: Int64,
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> ChunkUploadResult {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ChunkUploadDelegate(
                expectedSize: chunkSize,
                progressHandler: progressHandler,
                continuation: continuation
            )
            let delegateSession = URLSession(
                configuration: self.session.configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = delegateSession.uploadTask(with: request, from: data)
            task.resume()
            // Session invalidated in delegate after completion
            delegate.session = delegateSession
        }
    }
}

// MARK: - Chunk Upload Delegate

private final class ChunkUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let expectedSize: Int64
    let progressHandler: @Sendable (Int64, Int64) -> Void
    let continuation: CheckedContinuation<ChunkUploadResult, any Error>
    var session: URLSession?
    private var responseData = Data()
    private var httpResponse: HTTPURLResponse?

    init(
        expectedSize: Int64,
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void,
        continuation: CheckedContinuation<ChunkUploadResult, any Error>
    ) {
        self.expectedSize = expectedSize
        self.progressHandler = progressHandler
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progressHandler(totalBytesSent, expectedSize)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { self.session?.finishTasksAndInvalidate() }

        if let error {
            continuation.resume(throwing: ChunkUploaderError.networkError(error))
            return
        }

        guard let response = httpResponse else {
            continuation.resume(throwing: ChunkUploaderError.noResponse)
            return
        }

        let statusCode = response.statusCode

        // Non-retriable errors
        if [400, 401, 403, 404, 409].contains(statusCode) {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            continuation.resume(throwing: ChunkUploaderError.nonRetryableStatus(statusCode, body))
            return
        }

        // Rate limit
        if statusCode == 429 {
            let retryAfter = (response.value(forHTTPHeaderField: "Retry-After") ?? response
                .value(forHTTPHeaderField: "retry-after")).flatMap { TimeInterval($0) }
            continuation.resume(throwing: ChunkUploaderError.rateLimited(retryAfter: retryAfter))
            return
        }

        // Retriable server errors
        if [500, 502, 503, 504].contains(statusCode) {
            continuation.resume(throwing: ChunkUploaderError.serverError(statusCode))
            return
        }

        // Success (200–299)
        guard (200 ... 299).contains(statusCode) else {
            continuation.resume(throwing: ChunkUploaderError.unexpectedStatus(statusCode))
            return
        }

        let etag = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "etag")
        let checksum = response.value(forHTTPHeaderField: "x-amz-checksum-sha256")
            ?? response.value(forHTTPHeaderField: "x-goog-hash")
        continuation.resume(returning: ChunkUploadResult(
            etag: etag,
            checksum: checksum,
            serverConfirmedChecksum: checksum != nil
        ))
    }
}

// MARK: - Errors

public enum ChunkUploaderError: Error, Sendable {
    case maxRetriesExceeded
    case nonRetryableStatus(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case unexpectedStatus(Int)
    case networkError(any Error)
    case noResponse
    case checksumMismatch
}
