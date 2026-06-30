import Foundation
import os.log

// MARK: - UploadScheduler

// Manages global concurrency: which files upload and in what order.
// Small files promoted ahead of large ones for better perceived throughput.

public actor UploadScheduler {
    public var maxConcurrentFiles: Int = 4
    public var maxConcurrentChunksTotal: Int = 32
    public var maxBandwidthBPS: Double?

    private let queue = UploadQueue()
    private var activeTasks: [UUID: UploadTask] = [:]
    private var pausedAll = false
    private let throttle = UploadThrottlePolicy.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "UploadScheduler")

    /// Slot availability stream
    private var slotContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    // MARK: - Queue Management

    public func enqueue(_ task: UploadTask, priority: TaskPriority = .normal) async {
        await queue.enqueue(task)
        let count = await queue.count
        logger.debug("Enqueued \(task.sourceURL.lastPathComponent) — queue size: \(count)")
        notifySlotAvailable()
    }

    public func dequeue(taskID: UUID) async {
        await queue.remove(taskID: taskID)
        activeTasks.removeValue(forKey: taskID)
        notifySlotAvailable()
    }

    public func takeQueuedTask(taskID: UUID) async -> UploadTask? {
        let task = await queue.removeAndReturn(taskID: taskID)
        if task != nil { notifySlotAvailable() }
        return task
    }

    @discardableResult
    public func reprioritize(taskID: UUID, to priority: TaskPriority) async -> Bool {
        let changed = await queue.reprioritize(taskID: taskID, to: priority)
        if changed { notifySlotAvailable() }
        return changed
    }

    public func setMaxConcurrentFiles(_ n: Int) {
        maxConcurrentFiles = n
    }

    public func pauseAll() {
        pausedAll = true
        logger.info("All uploads paused")
    }

    public func resumeAll() {
        pausedAll = false
        notifySlotAvailable()
        logger.info("All uploads resumed")
    }

    public func cancelAll() async {
        let ids = Array(activeTasks.keys)
        for id in ids {
            activeTasks.removeValue(forKey: id)
        }
        // Drain queue
        while await queue.peek != nil {
            _ = await queue.dequeue()
        }
        notifySlotAvailable()
    }

    // MARK: - Slot Management

    /// Waits until a slot is free, then returns the next task to execute.
    public func nextTask() async -> UploadTask? {
        while true {
            if pausedAll {
                await waitForSlot()
                continue
            }
            if activeTasks.count >= maxConcurrentFiles {
                await waitForSlot()
                continue
            }
            guard let task = await queue.dequeue() else {
                await waitForSlot()
                continue
            }
            activeTasks[task.id] = task
            return task
        }
    }

    public func markComplete(taskID: UUID) {
        activeTasks.removeValue(forKey: taskID)
        notifySlotAvailable()
    }

    public func markPaused(taskID: UUID) {
        activeTasks.removeValue(forKey: taskID)
        notifySlotAvailable()
    }

    public func markFailed(taskID: UUID) {
        activeTasks.removeValue(forKey: taskID)
        notifySlotAvailable()
    }

    // MARK: - Bandwidth Schedule Management

    public func addBandwidthSchedule(_ schedule: BandwidthSchedule) async {
        await throttle.addSchedule(schedule)
    }

    public func clearBandwidthSchedules() async {
        await throttle.removeAllSchedules()
    }

    public func setManualBandwidthLimit(_ bps: Double?) async {
        await throttle.setManualLimit(bps)
        maxBandwidthBPS = bps
    }

    // MARK: - Stats

    public var activeCount: Int {
        activeTasks.count
    }

    public var queuedCount: Int {
        get async { await queue.count }
    }

    public var isPaused: Bool {
        pausedAll
    }

    public var allTasks: [UploadTask] {
        get async {
            let queued = await queue.tasks
            return Array(activeTasks.values) + queued
        }
    }

    // MARK: - Private

    private func notifySlotAvailable() {
        for continuation in slotContinuations.values {
            continuation.yield(())
        }
    }

    private func waitForSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = UUID()
            let stream = AsyncStream<Void> { c in
                slotContinuations[id] = c
                c.onTermination = { [weak self] _ in
                    Task { [weak self] in await self?.removeSlotContinuation(id: id) }
                }
            }
            Task {
                for await _ in stream {
                    break
                }
                continuation.resume()
            }
        }
    }

    private func removeSlotContinuation(id: UUID) {
        slotContinuations.removeValue(forKey: id)
    }
}
