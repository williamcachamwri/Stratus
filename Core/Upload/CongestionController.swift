import Foundation
import os.log

// MARK: - Congestion Mode

public enum CongestionMode: Sendable {
    case slowStart
    case avoidance
    case recovery
}

// MARK: - CongestionController

// TCP-inspired AIMD: Additive Increase / Multiplicative Decrease
// Finds optimal upload parallelism automatically without overwhelming server.

public actor CongestionController {
    private var windowSize: Double = 4.0
    private var ssthresh: Double = 32.0
    public private(set) var mode: CongestionMode = .slowStart

    private let minWindow: Double = 1.0
    private let maxWindow: Double
    private var lastRTT: TimeInterval = 0
    private var rttSamples: [TimeInterval] = []
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "CongestionController")
    private let highRTTThreshold: TimeInterval = 0.25

    public init(maxConcurrentStreams: Int = 32) {
        maxWindow = Double(maxConcurrentStreams)
    }

    // MARK: - Event Handlers

    /// Called after every successful chunk upload
    public func onChunkSuccess(rtt: TimeInterval) {
        rttSamples.append(rtt)
        if rttSamples.count > 10 { rttSamples.removeFirst() }
        lastRTT = rtt

        switch mode {
        case .slowStart:
            let targetThreshold = rtt >= highRTTThreshold ? min(ssthresh, 16.0) : ssthresh
            windowSize = min(windowSize * 2.0, targetThreshold)
            if windowSize >= targetThreshold {
                mode = .avoidance
                logger.debug("Congestion: entering avoidance at window=\(self.windowSize)")
            }

        case .avoidance:
            // Additive increase: +1/windowSize per ACK ≈ +1 per RTT
            windowSize += 1.0 / windowSize

        case .recovery:
            // Slow recovery: +1 per RTT
            windowSize += 1.0
            if windowSize >= ssthresh {
                mode = .avoidance
            }
        }

        windowSize = clamp(windowSize)
    }

    /// Called on upload timeout
    public func onChunkTimeout() {
        ssthresh = max(windowSize / 2.0, minWindow)
        windowSize = minWindow
        mode = .slowStart
        logger.debug("Congestion: timeout — ssthresh=\(self.ssthresh), restarting slow start")
    }

    /// Called on 429 Too Many Requests
    public func onChunkRateLimited(retryAfter: TimeInterval) {
        ssthresh = max(windowSize / 2.0, minWindow)
        windowSize = max(minWindow, windowSize * 0.5)
        mode = .recovery
        logger.debug("Congestion: rate limited — window=\(self.windowSize), retry after \(retryAfter)s")
    }

    /// Called on non-timeout errors (network errors, 5xx)
    public func onChunkError() {
        ssthresh = max(windowSize / 2.0, minWindow)
        windowSize = max(minWindow, windowSize * 0.5)
        mode = .recovery
        logger.debug("Congestion: error — window=\(self.windowSize)")
    }

    // MARK: - Recommendation

    public var recommendedParallelism: Int {
        Int(clamp(windowSize))
    }

    public var smoothedRTT: TimeInterval {
        guard !rttSamples.isEmpty else { return 0 }
        return rttSamples.reduce(0, +) / Double(rttSamples.count)
    }

    public var windowSizeForTesting: Double {
        windowSize
    }

    public var ssthreshForTesting: Double {
        ssthresh
    }

    public func setWindowForTesting(_ value: Double) {
        windowSize = value
        if windowSize >= ssthresh { mode = .avoidance }
    }

    // MARK: - Private

    private func clamp(_ value: Double) -> Double {
        min(maxWindow, max(minWindow, value))
    }
}
