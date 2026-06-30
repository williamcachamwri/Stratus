import Foundation
import os.log

// MARK: - DownloadEngineEvent

public enum DownloadEngineEvent: Sendable {
    case taskAdded(DownloadTask)
    case taskStarted(UUID)
    case taskProgress(UUID, DownloadProgress)
    case taskCompleted(UUID, DownloadSummary)
    case taskFailed(UUID, DownloadError)
    case taskPaused(UUID, DownloadResumeToken?)
    case taskResumed(UUID)
    case taskCancelled(UUID)
    case sessionsRestored(count: Int)
}

// MARK: - DownloadEngineConfiguration

public struct DownloadEngineConfiguration: Sendable {
    /// Maximum number of file downloads that may run concurrently.
    public let maxConcurrentDownloads: Int
    /// Configuration forwarded to each ParallelRangeDownloader instance.
    public let rangeDownloaderConfiguration: ParallelRangeDownloaderConfiguration
    /// Directory where staging files are written during download. Defaults to
    /// the system's temporary directory.
    public let stagingDirectory: URL
    /// Maximum number of per-task retries before the task is permanently failed.
    public let maxTaskRetries: Int

    public static let `default` = DownloadEngineConfiguration()

    public init(
        maxConcurrentDownloads: Int = 3,
        rangeDownloaderConfiguration: ParallelRangeDownloaderConfiguration = .default,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StratusDownloads", isDirectory: true),
        maxTaskRetries: Int = 4
    ) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.rangeDownloaderConfiguration = rangeDownloaderConfiguration
        self.stagingDirectory = stagingDirectory
        self.maxTaskRetries = maxTaskRetries
    }
}

// MARK: - DownloadEngine

/// Top-level actor that orchestrates downloads.
///
/// Responsibilities:
/// - Accepts new `DownloadTask` submissions from the UI / sync layer.
/// - Runs up to `configuration.maxConcurrentDownloads` transfers in parallel.
/// - Delegates byte-range I/O to `ParallelRangeDownloader`.
/// - Persists progress via `DownloadResumeStore` so incomplete downloads
///   survive app restart.
/// - Emits structured `DownloadEngineEvent` values via `AsyncStream`.
public actor DownloadEngine {
    // MARK: Shared instance

    public static let shared = DownloadEngine()

    // MARK: Dependencies

    private let resumeStore: DownloadResumeStore
    private let configuration: DownloadEngineConfiguration
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DownloadEngine")

    // MARK: Registered providers / accounts

    /// Keyed by `CloudAccount.id`.
    private var providers: [String: any CloudProvider] = [:]
    private var accounts: [String: CloudAccount] = [:]

    // MARK: Internal state

    private var queue: [DownloadTask] = [] // pending tasks, priority-ordered
    private var activeTasks: [UUID: DownloadTask] = [:] // currently running
    private var taskHandles: [UUID: Task<Void, Never>] = [:] // backing Tasks
    private var eventContinuations: [UUID: AsyncStream<DownloadEngineEvent>.Continuation] = [:]
    private var runLoopHandle: Task<Void, Never>?

    // MARK: Init

    public init(
        resumeStore: DownloadResumeStore = .shared,
        configuration: DownloadEngineConfiguration = .default
    ) {
        self.resumeStore = resumeStore
        self.configuration = configuration
    }

    // MARK: - Provider Registration

    public func registerProvider(_ provider: any CloudProvider, account: CloudAccount) {
        providers[account.id] = provider
        accounts[account.id] = account
        logger.debug("Registered provider \(provider.id) for account \(account.id)")
    }

    // MARK: - Lifecycle

    /// Start the engine: prepare the schema, restore interrupted sessions, and
    /// begin the scheduling run loop.
    public func start() async {
        do {
            try await resumeStore.prepareSchema()
        } catch {
            logger.error("Failed to prepare DownloadResumeStore schema: \(error)")
        }

        do {
            try FileManager.default.createDirectory(
                at: configuration.stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create staging directory: \(error)")
        }

        await restoreInterruptedSessions()

        runLoopHandle = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("DownloadEngine started")
    }

    /// Gracefully stop: pause all active downloads so they can be resumed later.
    public func stop() async {
        runLoopHandle?.cancel()
        runLoopHandle = nil

        for id in activeTasks.keys {
            await pauseInternal(taskID: id)
        }
        logger.info("DownloadEngine stopped")
    }

    // MARK: - Task Submission

    /// Enqueue a new download. Returns the task ID.
    @discardableResult
    public func download(
        path: CloudPath,
        to destination: URL,
        accountID: String,
        providerID: String,
        expectedSize: Int64? = nil,
        priority: DownloadPriority = .normal
    ) async throws -> UUID {
        guard accounts[accountID] != nil else {
            throw DownloadError.providerError("No account registered for ID: \(accountID)")
        }

        let task = DownloadTask(
            sourcePath: path,
            destinationURL: destination,
            accountID: accountID,
            providerID: providerID,
            expectedSize: expectedSize,
            priority: priority
        )

        let stagingURL = configuration.stagingDirectory
            .appendingPathComponent(task.id.uuidString + ".part")
        task.setStagingURL(stagingURL)

        // Persist a session record immediately so a crash before the first
        // segment doesn't lose the intent.
        let session = DownloadSession(
            id: task.id.uuidString,
            providerID: providerID,
            accountID: accountID,
            remotePath: path.path,
            destinationPath: destination.path,
            stagingPath: stagingURL.path,
            expectedSize: expectedSize ?? 0,
            priority: priority.rawValue
        )
        try await resumeStore.upsert(session)

        enqueueTask(task)
        emit(.taskAdded(task))
        logger.info("Queued download \(path) → \(destination.lastPathComponent) [priority=\(priority.rawValue)]")
        return task.id
    }

    // MARK: - Control

    public func pause(taskID: UUID) async {
        await pauseInternal(taskID: taskID)
    }

    public func resume(taskID: UUID) async {
        // Re-activate a task that was previously paused. The task object is
        // already in `activeTasks` or needs to be re-queued.
        guard let task = activeTasks[taskID] else {
            logger.warning("Resume requested for unknown task \(taskID)")
            return
        }
        guard case .paused = task.state else { return }

        task.transition(to: .queued(priority: task.priority))
        activeTasks.removeValue(forKey: taskID)
        enqueueTask(task)
        emit(.taskResumed(taskID))
    }

    public func cancel(taskID: UUID) async {
        taskHandles[taskID]?.cancel()
        taskHandles.removeValue(forKey: taskID)
        activeTasks.removeValue(forKey: taskID)
        queue.removeAll { $0.id == taskID }

        do {
            try await resumeStore.delete(sessionID: taskID.uuidString)
        } catch {
            logger.warning("Could not delete session for cancelled task \(taskID): \(error)")
        }

        emit(.taskCancelled(taskID))
        logger.info("Cancelled download \(taskID)")
    }

    public func pauseAll() async {
        for id in activeTasks.keys {
            await pauseInternal(taskID: id)
        }
    }

    public func resumeAll() async {
        let ids = activeTasks.keys
        for id in ids {
            await resume(taskID: id)
        }
    }

    public func cancelAll() async {
        let ids = Array(activeTasks.keys) + queue.map(\.id)
        for id in ids {
            await cancel(taskID: id)
        }
    }

    // MARK: - Events

    /// Subscribe to engine events. Each call returns a distinct stream; all
    /// subscribers receive every event (fan-out). Streams are automatically
    /// cleaned up when the consumer stops iterating.
    public var events: AsyncStream<DownloadEngineEvent> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.addEventContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeEventContinuation(id: id) }
            }
        }
    }

    // MARK: - Run Loop

    private func runLoop() async {
        while !Task.isCancelled {
            drainQueue()
            // Yield so other actor work can run before we check again.
            await Task.yield()
        }
    }

    /// Promotes queued tasks up to the concurrency limit.
    private func drainQueue() {
        let available = configuration.maxConcurrentDownloads - activeTasks.count
        guard available > 0, !queue.isEmpty else { return }

        for _ in 0 ..< available {
            guard let task = queue.first else { break }
            queue.removeFirst()
            activeTasks[task.id] = task
            startTask(task)
        }
    }

    // MARK: - Task Execution

    private func startTask(_ task: DownloadTask) {
        let handle: Task<Void, Never> = Task { [weak self] in
            await self?.executeTask(task)
        }
        taskHandles[task.id] = handle
        emit(.taskStarted(task.id))
    }

    private func executeTask(_ task: DownloadTask) async {
        guard
            let provider = providers[task.accountID],
            let account = accounts[task.accountID]
        else {
            let err = DownloadError.providerError("Provider not found for account \(task.accountID)")
            await finishTask(task, with: .failure(err))
            return
        }

        let fileSize: Int64
        if let expected = task.expectedSize, expected > 0 {
            fileSize = expected
        } else {
            // Probe the server for the file size.
            do {
                let meta = try await provider.fileMetadata(path: task.sourcePath, account: account)
                fileSize = meta.size ?? 0
            } catch let provErr as ProviderError {
                if case let .fileNotFound(p) = provErr {
                    await finishTask(task, with: .failure(.fileNotFound(p)))
                } else {
                    await finishTask(task, with: .failure(.providerError(provErr.localizedDescription)))
                }
                return
            } catch {
                await finishTask(task, with: .failure(.unknown(error.localizedDescription)))
                return
            }
        }

        // Load prior segment progress for resume.
        let alreadyCompleted: Set<Int> = if let session = try? await resumeStore.load(sessionID: task.id.uuidString) {
            session.completedSegmentSet
        } else {
            []
        }

        let stagingURL = task.stagingURL ?? configuration.stagingDirectory
            .appendingPathComponent(task.id.uuidString + ".part")

        task.transition(to: .downloading(progress: DownloadProgress(
            totalBytes: fileSize,
            receivedBytes: 0,
            segmentsTotal: 0,
            segmentsCompleted: alreadyCompleted.count,
            segmentsInFlight: 0,
            currentSpeedBPS: 0,
            estimatedSecondsRemaining: nil
        )))

        let startTime = Date()
        let downloader = ParallelRangeDownloader(
            provider: provider,
            configuration: configuration.rangeDownloaderConfiguration
        )

        // The progress handler is called from within the downloader's actor
        // context; we hop back to the engine actor to update shared state.
        let taskID = task.id
        let segmentSize = configuration.rangeDownloaderConfiguration.segmentSize
        let segmentsUsed = Int((fileSize + segmentSize - 1) / segmentSize)

        do {
            let result = try await downloader.downloadToFile(
                path: task.sourcePath,
                fileSize: fileSize,
                account: account,
                destination: stagingURL,
                alreadyCompletedSegmentIndices: alreadyCompleted
            ) { [weak self] update in
                Task { [weak self] in
                    await self?.handleSegmentProgress(
                        taskID: taskID,
                        update: update,
                        startTime: startTime,
                        fileSize: fileSize
                    )
                }
            }
            _ = result // destination URL; already known

            // Move staging file to the final destination.
            do {
                let fm = FileManager.default
                let destDir = task.destinationURL.deletingLastPathComponent()
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: task.destinationURL.path) {
                    try fm.removeItem(at: task.destinationURL)
                }
                try fm.moveItem(at: stagingURL, to: task.destinationURL)
            } catch {
                await finishTask(task, with: .failure(.localIOError(error.localizedDescription)))
                return
            }

            let duration = Date().timeIntervalSince(startTime)
            let summary = DownloadSummary(
                totalBytes: fileSize,
                durationSeconds: duration,
                averageBPS: duration > 0 ? Double(fileSize) / duration : 0,
                segmentsUsed: segmentsUsed,
                localURL: task.destinationURL,
                checksumVerified: false // post-download verification is a caller responsibility
            )

            await finishTask(task, with: .success(summary))
        } catch let dlErr {
            if task.retryCount < configuration.maxTaskRetries, isRetryable(dlErr) {
                task.incrementRetry()
                try? await resumeStore.incrementRetryCount(sessionID: taskID.uuidString)
                logger.warning("Task \(taskID) failed (attempt \(task.retryCount)); re-queuing")
                task.transition(to: .queued(priority: task.priority))
                activeTasks.removeValue(forKey: taskID)
                taskHandles.removeValue(forKey: taskID)
                enqueueTask(task)
            } else {
                await finishTask(task, with: .failure(dlErr))
            }
        }
    }

    private func handleSegmentProgress(
        taskID: UUID,
        update: SegmentProgressUpdate,
        startTime: Date,
        fileSize: Int64
    ) async {
        let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
        let bps = Double(update.bytesReceived) / elapsed
        let remaining: Double? = bps > 0 && fileSize > 0
            ? Double(fileSize - update.bytesReceived) / bps
            : nil

        let progress = DownloadProgress(
            totalBytes: fileSize,
            receivedBytes: update.bytesReceived,
            segmentsTotal: update.segmentsTotal,
            segmentsCompleted: update.segmentsCompleted,
            segmentsInFlight: update.segmentsTotal - update.segmentsCompleted,
            currentSpeedBPS: bps,
            estimatedSecondsRemaining: remaining
        )

        activeTasks[taskID]?.transition(to: .downloading(progress: progress))
        emit(.taskProgress(taskID, progress))

        // Persist the high-water mark after each segment.
        let hwm = Int64(update.segmentsCompleted) * configuration.rangeDownloaderConfiguration.segmentSize
        try? await resumeStore.markSegmentComplete(
            sessionID: taskID.uuidString,
            segmentIndex: update.segmentsCompleted - 1,
            newHighWaterOffset: hwm
        )
    }

    // MARK: - Finish / Pause helpers

    private enum TaskOutcome {
        case success(DownloadSummary)
        case failure(DownloadError)
    }

    private func finishTask(_ task: DownloadTask, with outcome: TaskOutcome) async {
        taskHandles.removeValue(forKey: task.id)
        activeTasks.removeValue(forKey: task.id)

        switch outcome {
        case let .success(summary):
            task.transition(to: .completed(summary: summary))
            try? await resumeStore.updateState(sessionID: task.id.uuidString, state: "completed")
            emit(.taskCompleted(task.id, summary))
            logger
                .info(
                    "Download complete: \(task.sourcePath) (\(summary.totalBytes) bytes in \(String(format: "%.1f", summary.durationSeconds))s)"
                )

        case let .failure(err):
            task.transition(to: .failed(error: err, attempt: task.retryCount))
            try? await resumeStore.updateState(
                sessionID: task.id.uuidString,
                state: "failed",
                errorDescription: err.localizedDescription
            )
            emit(.taskFailed(task.id, err))
            logger.error("Download failed: \(task.sourcePath) — \(String(describing: err))")
        }

        drainQueue()
    }

    private func pauseInternal(taskID: UUID) async {
        guard let task = activeTasks[taskID] else { return }

        taskHandles[taskID]?.cancel()
        taskHandles.removeValue(forKey: taskID)

        let token = DownloadResumeToken(
            sessionID: taskID.uuidString,
            resumeOffset: {
                if case let .downloading(p) = task.state {
                    return p.receivedBytes
                }
                return 0
            }()
        )
        task.transition(to: .paused(resumeToken: token))
        try? await resumeStore.updateState(sessionID: taskID.uuidString, state: "paused")
        emit(.taskPaused(taskID, token))
        logger.info("Paused download \(taskID)")
    }

    // MARK: - Session Restoration

    private func restoreInterruptedSessions() async {
        do {
            let sessions = try await resumeStore.loadResumableSessions()
            guard !sessions.isEmpty else { return }

            for session in sessions {
                guard
                    UUID(uuidString: session.id) != nil,
                    let priority = DownloadPriority(rawValue: session.priority)
                else { continue }

                let id = UUID(uuidString: session.id) ?? UUID()
                let stagingURL = URL(fileURLWithPath: session.stagingPath)
                let destinationURL = URL(fileURLWithPath: session.destinationPath)
                let resumeToken = DownloadResumeToken(
                    sessionID: session.id,
                    resumeOffset: session.highWaterOffset
                )

                let task = DownloadTask(
                    id: id,
                    sourcePath: CloudPath(session.remotePath),
                    destinationURL: destinationURL,
                    accountID: session.accountID,
                    providerID: session.providerID,
                    expectedSize: session.expectedSize > 0 ? session.expectedSize : nil,
                    priority: priority,
                    state: .paused(resumeToken: resumeToken)
                )
                task.setStagingURL(stagingURL)
                enqueueTask(task)
            }

            emit(.sessionsRestored(count: sessions.count))
            logger.info("Restored \(sessions.count) interrupted download sessions")
        } catch {
            logger.error("Failed to restore download sessions: \(error)")
        }
    }

    // MARK: - Queue management

    /// Insert `task` into `queue` maintaining descending priority order.
    private func enqueueTask(_ task: DownloadTask) {
        let insertionIndex = queue.firstIndex { existing in
            existing.priority < task.priority
        } ?? queue.endIndex
        queue.insert(task, at: insertionIndex)
    }

    // MARK: - Retry policy

    private func isRetryable(_ error: DownloadError) -> Bool {
        switch error {
        case .networkUnavailable, .segmentFailed, .unknown:
            true
        case .fileNotFound, .checksumMismatch, .insufficientDiskSpace,
             .localIOError, .authenticationFailed, .cancelled,
             .providerError, .rangesNotSupported, .maxRetriesExceeded:
            false
        }
    }

    // MARK: - Event fan-out

    private func emit(_ event: DownloadEngineEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func addEventContinuation(
        id: UUID,
        continuation: AsyncStream<DownloadEngineEvent>.Continuation
    ) {
        eventContinuations[id] = continuation
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
