import Foundation
import os.log

// MARK: - Upload Engine Events

public enum UploadEngineEvent: Sendable {
    case taskAdded(UploadTask)
    case taskStarted(UUID)
    case taskProgress(UUID, ChunkProgress)
    case taskCompleted(UploadTask, UploadResult)
    case taskFailed(UploadTask, UploadError)
    case taskPaused(UUID)
    case taskResumed(UUID)
    case taskReprioritized(UUID, TaskPriority)
    case taskCancelled(UUID)
    case sessionRestored(count: Int)
}

// MARK: - UploadEngine
// Top-level actor: receives tasks, drives the scheduler, spawns ChunkEngine workers.

public actor UploadEngine {
    public static let shared = UploadEngine()

    private let scheduler = UploadScheduler()
    private let bandwidthMonitor = BandwidthMonitor()
    private let congestionController = CongestionController()
    private let deltaSync = DeltaSync()
    private let checksumEngine = ChecksumEngine.shared
    private let resumeStore = ResumeStore.shared
    private let metrics = UploadMetricsCollector.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "UploadEngine")

    private var providers: [String: any CloudProvider] = [:]
    private var accounts: [String: CloudAccount] = [:]
    private var eventContinuations: [UUID: AsyncStream<UploadEngineEvent>.Continuation] = [:]
    private var runLoopTask: Task<Void, Never>?
    private var progressStreams: [UUID: AsyncStream<ChunkProgress>.Continuation] = [:]
    private var activeUploadTasks: [UUID: Task<Void, Never>] = [:]
    private var pausedQueuedTasks: [UUID: UploadTask] = [:]

    private init() {}

    // MARK: - Setup

    public func registerProvider(_ provider: any CloudProvider, account: CloudAccount) {
        providers[account.id] = provider
        accounts[account.id] = account
    }

    public func configure(maxConcurrentFiles: Int, maxBandwidthBPS: Double?) async {
        await scheduler.setManualBandwidthLimit(maxBandwidthBPS)
        await scheduler.setMaxConcurrentFiles(maxConcurrentFiles)
    }

    // MARK: - Lifecycle

    public func start() async {
        // Restore interrupted sessions from ResumeStore
        if let sessions = try? await resumeStore.loadPendingSessions(), !sessions.isEmpty {
            emit(.sessionRestored(count: sessions.count))
            logger.info("Restored \(sessions.count) interrupted upload sessions")
            // Re-queue pending sessions (they will resume from saved chunk state)
            for session in sessions {
                if accounts[session.accountID] != nil {
                    do {
                        let sourceURL = try resumeStore.resolvedFileURL(for: session)
                        let task = UploadTask(
                            id: UUID(uuidString: session.id) ?? UUID(),
                            sourceURL: sourceURL,
                            destinationPath: CloudPath(session.remotePath),
                            accountID: session.accountID,
                            providerID: session.providerID,
                            fileSize: session.fileSize,
                            localChecksum: session.fileChecksum,
                            state: .queued(priority: .normal)
                        )
                        task.setUploadID(session.uploadID ?? "")
                        await scheduler.enqueue(task, priority: .normal)
                    } catch {
                        try? await resumeStore.updateSessionState(session.id, state: "failed", error: "Could not resolve security-scoped bookmark: \(error)")
                    }
                }
            }
        }

        runLoopTask = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("UploadEngine started")
    }

    public func stop() {
        runLoopTask?.cancel()
        runLoopTask = nil
    }

    // MARK: - Task Submission

    public func upload(
        fileURL: URL,
        destination: CloudPath,
        accountID: String,
        priority: TaskPriority = .normal,
        metadata: UploadMetadata = UploadMetadata()
    ) async throws -> UUID {
        guard let account = accounts[accountID] else {
            throw UploadError.providerError("No account registered for ID: \(accountID)")
        }

        // Hash the file to detect changes and enable delta sync
        let checksum = try await checksumEngine.sha256Stream(url: fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let task = UploadTask(
            sourceURL: fileURL,
            destinationPath: destination,
            accountID: accountID,
            providerID: account.providerID,
            fileSize: fileSize,
            localChecksum: checksum,
            priority: priority,
            metadata: metadata
        )

        emit(.taskAdded(task))
        await scheduler.enqueue(task, priority: priority)
        logger.info("Queued \(fileURL.lastPathComponent) (\(fileSize) bytes) → \(destination)")
        return task.id
    }

    public func pause(taskID: UUID) async {
        if let activeTask = activeUploadTasks[taskID] {
            activeTask.cancel()
            try? await resumeStore.updateSessionState(taskID.uuidString, state: "paused")
            emit(.taskPaused(taskID))
            return
        }

        if let queuedTask = await scheduler.takeQueuedTask(taskID: taskID) {
            queuedTask.transition(to: .paused(resumeToken: queuedTask.uploadID))
            pausedQueuedTasks[taskID] = queuedTask
            try? await resumeStore.updateSessionState(taskID.uuidString, state: "paused")
            emit(.taskPaused(taskID))
        }
    }

    public func resume(taskID: UUID) async {
        if let pausedTask = pausedQueuedTasks.removeValue(forKey: taskID) {
            pausedTask.transition(to: .queued(priority: pausedTask.priority))
            await scheduler.enqueue(pausedTask, priority: pausedTask.priority)
            emit(.taskResumed(taskID))
            return
        }

        if let inMemoryTask = await scheduler.allTasks.first(where: { $0.id == taskID }) {
            inMemoryTask.transition(to: .queued(priority: inMemoryTask.priority))
            await scheduler.enqueue(inMemoryTask, priority: inMemoryTask.priority)
            emit(.taskResumed(taskID))
            return
        }

        do {
            guard let session = try await resumeStore.loadSession(taskID.uuidString) else {
                logger.warning("Resume requested for unknown upload task \(taskID)")
                return
            }

            let sourceURL = try resumeStore.resolvedFileURL(for: session)
            let task = UploadTask(
                id: taskID,
                sourceURL: sourceURL,
                destinationPath: CloudPath(session.remotePath),
                accountID: session.accountID,
                providerID: session.providerID,
                fileSize: session.fileSize,
                localChecksum: session.fileChecksum,
                priority: .normal,
                state: .queued(priority: .normal)
            )
            task.setUploadID(session.uploadID ?? "")
            await scheduler.enqueue(task, priority: task.priority)
            emit(.taskResumed(taskID))
        } catch {
            logger.error("Failed to resume upload task \(taskID): \(error.localizedDescription)")
        }
    }

    public func reprioritize(taskID: UUID, to priority: TaskPriority = .critical) async {
        guard activeUploadTasks[taskID] == nil else {
            logger.debug("Ignoring priority change for active upload task \(taskID)")
            return
        }
        if await scheduler.reprioritize(taskID: taskID, to: priority) {
            emit(.taskReprioritized(taskID, priority))
        }
    }

    public func cancel(taskID: UUID) async {
        activeUploadTasks[taskID]?.cancel()
        activeUploadTasks.removeValue(forKey: taskID)
        progressStreams[taskID]?.finish()
        progressStreams.removeValue(forKey: taskID)
        pausedQueuedTasks.removeValue(forKey: taskID)
        await scheduler.dequeue(taskID: taskID)
        try? await resumeStore.updateSessionState(taskID.uuidString, state: "cancelled")
        emit(.taskCancelled(taskID))
    }

    public func pauseAll() async {
        for id in activeUploadTasks.keys {
            activeUploadTasks[id]?.cancel()
            try? await resumeStore.updateSessionState(id.uuidString, state: "paused")
            emit(.taskPaused(id))
        }
        await scheduler.pauseAll()
    }

    public func resumeAll() async {
        await scheduler.resumeAll()
    }

    public func cancelAll() async {
        for id in activeUploadTasks.keys {
            activeUploadTasks[id]?.cancel()
            progressStreams[id]?.finish()
            emit(.taskCancelled(id))
        }
        activeUploadTasks.removeAll()
        progressStreams.removeAll()
        await scheduler.cancelAll()
    }

    // MARK: - Progress / Events

    public var events: AsyncStream<UploadEngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeEventContinuation(id: id) }
            }
        }
    }

    public var bandwidthUpdates: AsyncStream<BWSnapshot> {
        get async { await bandwidthMonitor.updates }
    }

    public var currentBPS: Double {
        get async { await bandwidthMonitor.currentBPS }
    }

    // MARK: - Run Loop

    private func runLoop() async {
        while !Task.isCancelled {
            guard let task = await scheduler.nextTask() else { continue }

            guard let provider = providers[task.accountID],
                  let account = accounts[task.accountID] else {
                await scheduler.markFailed(taskID: task.id)
                emit(.taskFailed(task, .providerError("Provider not found for account \(task.accountID)")))
                continue
            }

            emit(.taskStarted(task.id))

            // Progress stream for this task
            let (progressStream, progressContinuation) = AsyncStream<ChunkProgress>.makeStream()
            progressStreams[task.id] = progressContinuation

            // Forward progress events
            let taskID = task.id
            Task { [weak self] in
                for await progress in progressStream {
                    await self?.emit(.taskProgress(taskID, progress))
                }
            }

            // Execute upload
            let engineBandwidthMonitor = bandwidthMonitor
            let engineCongestionController = congestionController
            let engineLogger = logger
            let uploadTask = Task { [weak self] in
                let chunkEngine = ChunkEngine()
                do {
                    let result = try await chunkEngine.upload(
                        task: task,
                        provider: provider,
                        account: account,
                        bandwidthMonitor: engineBandwidthMonitor,
                        congestionController: engineCongestionController,
                        progressStream: progressContinuation
                    )
                    progressContinuation.finish()
                    await self?.removeProgressStream(forKey: taskID)
                    await self?.removeActiveUploadTask(forKey: taskID)
                    await self?.scheduler.markComplete(taskID: taskID)
                    await self?.emit(.taskCompleted(task, result))
                    engineLogger.info("Completed \(task.sourceURL.lastPathComponent) — \(result.bytesUploaded) bytes in \(String(format: "%.1f", result.durationSeconds))s")
                } catch UploadError.cancelled {
                    progressContinuation.finish()
                    await self?.removeProgressStream(forKey: taskID)
                    await self?.removeActiveUploadTask(forKey: taskID)
                    await self?.scheduler.markPaused(taskID: taskID)
                    task.transition(to: .paused(resumeToken: task.uploadID))
                    await self?.emit(.taskPaused(taskID))
                } catch {
                    progressContinuation.finish()
                    await self?.removeProgressStream(forKey: taskID)
                    await self?.removeActiveUploadTask(forKey: taskID)
                    await self?.scheduler.markFailed(taskID: taskID)
                    let uploadError = error as? UploadError ?? .unknown(error.localizedDescription)
                    await self?.emit(.taskFailed(task, uploadError))
                    engineLogger.error("Failed \(task.sourceURL.lastPathComponent): \(error)")
                }
            }
            activeUploadTasks[taskID] = uploadTask
        }
    }

    // MARK: - Private

    private func emit(_ event: UploadEngineEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func removeProgressStream(forKey id: UUID) {
        progressStreams.removeValue(forKey: id)
    }

    private func removeActiveUploadTask(forKey id: UUID) {
        activeUploadTasks.removeValue(forKey: id)
    }
}
