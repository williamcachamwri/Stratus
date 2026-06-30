import Foundation

// MARK: - UploadQueue

// Observable priority queue backed by a heap.
// Higher priority dequeued first; equal priority → smaller file first.

public actor UploadQueue {
    private var heap: [UploadTask] = []
    private var tasksByID: [UUID: UploadTask] = [:]
    private var continuations: [UUID: AsyncStream<[UploadTask]>.Continuation] = [:]

    public init() {}

    // MARK: - Mutation

    public func enqueue(_ task: UploadTask) {
        heap.append(task)
        tasksByID[task.id] = task
        siftUp(from: heap.count - 1)
        notifyObservers()
    }

    public func dequeue() -> UploadTask? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let task = heap.removeLast()
        tasksByID.removeValue(forKey: task.id)
        if !heap.isEmpty { siftDown(from: 0) }
        notifyObservers()
        return task
    }

    public func remove(taskID: UUID) {
        _ = removeAndReturn(taskID: taskID)
    }

    @discardableResult
    public func removeAndReturn(taskID: UUID) -> UploadTask? {
        guard let idx = heap.firstIndex(where: { $0.id == taskID }) else { return nil }
        heap.swapAt(idx, heap.count - 1)
        let task = heap.removeLast()
        tasksByID.removeValue(forKey: taskID)
        if idx < heap.count {
            siftDown(from: idx)
            siftUp(from: idx)
        }
        notifyObservers()
        return task
    }

    public func reprioritize(taskID: UUID, to priority: TaskPriority) -> Bool {
        guard let idx = heap.firstIndex(where: { $0.id == taskID }) else { return false }
        // Create replacement task with new priority
        let old = heap[idx]
        let updated = UploadTask(
            id: old.id,
            sourceURL: old.sourceURL,
            destinationPath: old.destinationPath,
            accountID: old.accountID,
            providerID: old.providerID,
            fileSize: old.fileSize,
            localChecksum: old.localChecksum,
            priority: priority,
            metadata: old.metadata,
            state: .queued(priority: priority)
        )
        if let uploadID = old.uploadID {
            updated.setUploadID(uploadID)
        }
        heap[idx] = updated
        tasksByID[taskID] = updated
        // Re-heapify: try both directions
        siftUp(from: idx)
        if let newIdx = heap.firstIndex(where: { $0.id == taskID }) {
            siftDown(from: newIdx)
        }
        notifyObservers()
        return true
    }

    // MARK: - Query

    public var count: Int {
        heap.count
    }

    public var isEmpty: Bool {
        heap.isEmpty
    }

    public var peek: UploadTask? {
        heap.first
    }

    public var tasks: [UploadTask] {
        heap
    }

    public func task(id: UUID) -> UploadTask? {
        tasksByID[id]
    }

    // MARK: - Observation

    public var taskStream: AsyncStream<[UploadTask]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(heap)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeContinuation(id: id) }
            }
        }
    }

    // MARK: - Heap Internals (max-heap by priority, tie-break by smaller file first)

    private func priority(of task: UploadTask) -> (Int, Int64) {
        (task.priority.rawValue, -task.fileSize) // negate size: smaller = higher
    }

    private func isHigherPriority(_ a: UploadTask, _ b: UploadTask) -> Bool {
        let pa = priority(of: a)
        let pb = priority(of: b)
        if pa.0 != pb.0 { return pa.0 > pb.0 }
        return pa.1 > pb.1 // smaller file (less negative) wins
    }

    private func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if isHigherPriority(heap[child], heap[parent]) {
                heap.swapAt(child, parent)
                child = parent
            } else { break }
        }
    }

    private func siftDown(from index: Int) {
        var parent = index
        let count = heap.count
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var highest = parent
            if left < count, isHigherPriority(heap[left], heap[highest]) { highest = left }
            if right < count, isHigherPriority(heap[right], heap[highest]) { highest = right }
            guard highest != parent else { break }
            heap.swapAt(parent, highest)
            parent = highest
        }
    }

    private func notifyObservers() {
        let snapshot = heap
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
