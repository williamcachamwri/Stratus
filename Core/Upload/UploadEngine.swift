import Foundation
import os.log

// MARK: - Upload Engine Events

public enum UploadEngineEvent: Sendable {
    case taskAdded(UploadTask)
    case taskStarted(UUID)
    case taskProgress(UUID, ChunkProgress)
    case taskCompleted(UUID, UploadResult)
    case taskFailed(UUID, UploadError)
    case taskPaused(UUID)
    case taskResumed(UUID)
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

    private init() {}

    // MARK: - Setup

    public func registerProvider(_ provider: some CloudProvider, account: CloudAccount) {
        providers[account.id] = provider
        accounts[account.id] = account
    }

    public func configure(maxConcurrentFiles: Int, maxBandwidthBPS: Double?) async {
        await scheduler.setManualBandwidthLimit(maxBandwidthBPS)
        scheduler.maxConcurrentFiles = maxConcurrentFiles
    }

    // MARK: - Lifecycle

    public func start() async {
        // Restore interrupted sessions from ResumeStore
        if let sessions = try? await resumeStore.loadPendingSessions(), !sessions.isEmpty {
            emit(.sessionRestored(count: sessions.count))
            logger.info("Restored \(sessions.count) interrupted upload sessions")
            // Re-queue pending sessions (they will resume from saved chunk state)
            for session in sessions {
                if let account = accounts[session.accountID] {
                    let task = UploadTask(
                        id: UUID(uuidString: session.id) ?? UUID(),
                        sourceURL: URL(fileURLWithPath: session.fileURLString),
                        destinationPath: CloudPath(session.remotePath),
                        accountID: session.accountID,
                        providerID: session.providerID,
                        fileSize: session.fileSize,
                        localChecksum: session.fileChecksum,
                        state: .paused(resumeToken: session.uploadID)
                    )
                    await scheduler.enqueue(task, priority: .normal)
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
        emit(.taskPaused(taskID))
    }

    public func resume(taskID: UUID) async {
        emit(.taskResumed(taskID))
        await scheduler.enqueue(
            UploadTask(id: taskID, sourceURL: URL(fileURLWithPath: ""), destinationPath: CloudPath("/"),
                       accountID: "", providerID: "", fileSize: 0, localChecksum: ""),
            priority: .normal
        )
    }

    public func cancel(taskID: UUID) async {
        await scheduler.dequeue(taskID: taskID)
        emit(.taskCancelled(taskID))
    }

    public func pauseAll() async {
        await scheduler.pauseAll()
    }

    public func resumeAll() async {
        await scheduler.resumeAll()
    }

    public func cancelAll() async {
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
                emit(.taskFailed(task.id, .providerError("Provider not found for account \(task.accountID)")))
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
            Task { [weak self] in
                let chunkEngine = ChunkEngine()
                do {
                    let result = try await chunkEngine.upload(
                        task: task,
                        provider: provider,
                        account: account,
                        bandwidthMonitor: await self?.bandwidthMonitor ?? BandwidthMonitor(),
                        congestionController: await self?.congestionController ?? CongestionController(),
                        progressStream: progressContinuation
                    )
                    progressContinuation.finish()
                    await self?.progressStreams.removeValue(forKey: taskID)
                    await self?.scheduler.markComplete(taskID: taskID)
                    await self?.emit(.taskCompleted(taskID, result))
                    await self?.logger.info("Completed \(task.sourceURL.lastPathComponent) — \(result.bytesUploaded) bytes in \(String(format: "%.1f", result.durationSeconds))s")
                } catch {
                    progressContinuation.finish()
                    await self?.progressStreams.removeValue(forKey: taskID)
                    await self?.scheduler.markFailed(taskID: taskID)
                    let uploadError = error as? UploadError ?? .unknown(error.localizedDescription)
                    await self?.emit(.taskFailed(taskID, uploadError))
                    await self?.logger.error("Failed \(task.sourceURL.lastPathComponent): \(error)")
                }
            }
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
}
