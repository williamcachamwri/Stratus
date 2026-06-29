import Foundation
import os.log

// MARK: - Ring Buffer

struct RingBuffer<T: Sendable>: Sendable {
    private var buffer: [T?]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    mutating func push(_ element: T) {
        buffer[writeIndex % capacity] = element
        writeIndex += 1
        if count < capacity { count += 1 }
    }

    var elements: [T] {
        guard count > 0 else { return [] }
        let start = count < capacity ? 0 : writeIndex % capacity
        var result: [T] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let index = (start + i) % capacity
            if let element = buffer[index] {
                result.append(element)
            }
        }
        return result
    }
}

// MARK: - Bandwidth Sample

struct BWSample: Sendable {
    let bytes: Int64
    let elapsed: TimeInterval
    var bps: Double { elapsed > 0 ? Double(bytes) / elapsed : 0 }
}

// MARK: - Bandwidth Snapshot (emitted to UI)

public struct BWSnapshot: Sendable {
    public let currentBPS: Double
    public let peakBPS: Double
    public let averageBPS: Double
    public let trend: BWTrend
    public let utilization: Double

    public init(currentBPS: Double, peakBPS: Double, averageBPS: Double, trend: BWTrend, utilization: Double) {
        self.currentBPS = currentBPS
        self.peakBPS = peakBPS
        self.averageBPS = averageBPS
        self.trend = trend
        self.utilization = utilization
    }
}

public enum BWTrend: Sendable {
    case rising, stable, falling
}

// MARK: - BandwidthMonitor Actor
// EWMA α = 0.2: weights recent samples higher without wild oscillation
// Measurement resolution: 100ms
// Smoothing window: 5 seconds (50 samples)
// UI updates: every 250ms

public actor BandwidthMonitor {
    private let alpha: Double = 0.2
    private var samples: RingBuffer<BWSample>
    private var ewmaValue: Double = 0
    private var previousEWMA: Double = 0
    private(set) public var peakBPS: Double = 0
    private var continuations: [UUID: AsyncStream<BWSnapshot>.Continuation] = [:]
    private var lastUpdateTime: Date = Date()
    private let theoreticalMaxBPS: Double
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BandwidthMonitor")

    public init(theoreticalMaxBPS: Double = Double.infinity) {
        self.samples = RingBuffer(capacity: 50)
        self.theoreticalMaxBPS = theoreticalMaxBPS
    }

    // MARK: - Recording

    public func recordBytes(_ count: Int64, elapsed: TimeInterval) {
        guard elapsed > 0, count >= 0 else { return }
        let sample = BWSample(bytes: count, elapsed: elapsed)
        samples.push(sample)

        // EWMA: S_n = α × x_n + (1-α) × S_(n-1)
        let instantBPS = sample.bps
        previousEWMA = ewmaValue
        ewmaValue = alpha * instantBPS + (1.0 - alpha) * ewmaValue

        if ewmaValue > peakBPS { peakBPS = ewmaValue }

        // Emit UI update at 250ms intervals
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) >= 0.25 {
            lastUpdateTime = now
            let snapshot = makeSnapshot()
            for continuation in continuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    // MARK: - Computed Properties

    public var currentBPS: Double { ewmaValue }

    public var averageBPS: Double {
        let all = samples.elements
        guard !all.isEmpty else { return 0 }
        let totalBytes = all.reduce(0) { $0 + $1.bytes }
        let totalTime = all.reduce(0) { $0 + $1.elapsed }
        guard totalTime > 0 else { return 0 }
        return Double(totalBytes) / totalTime
    }

    public var trend: BWTrend {
        let delta = ewmaValue - previousEWMA
        let threshold = ewmaValue * 0.05  // 5% change threshold
        if delta > threshold { return .rising }
        if delta < -threshold { return .falling }
        return .stable
    }

    public var utilization: Double {
        guard theoreticalMaxBPS.isFinite, theoreticalMaxBPS > 0 else { return 0 }
        return min(1.0, ewmaValue / theoreticalMaxBPS)
    }

    public func estimatedTimeRemaining(bytesLeft: Int64) -> TimeInterval {
        guard bytesLeft > 0, ewmaValue > 0 else { return TimeInterval.infinity }
        return Double(bytesLeft) / ewmaValue
    }

    // MARK: - Update Stream

    public var updates: AsyncStream<BWSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    public func reset() {
        samples = RingBuffer(capacity: 50)
        ewmaValue = 0
        previousEWMA = 0
        peakBPS = 0
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func makeSnapshot() -> BWSnapshot {
        BWSnapshot(
            currentBPS: currentBPS,
            peakBPS: peakBPS,
            averageBPS: averageBPS,
            trend: trend,
            utilization: utilization
        )
    }
}
