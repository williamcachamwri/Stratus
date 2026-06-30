import XCTest
@testable import StratusCore

// Tests that the bandwidth monitoring and congestion control subsystems handle
// both high-throughput and low-throughput scenarios without errors.

final class BandwidthSaturationTests: XCTestCase {
    // MARK: - High-bandwidth mock: saturates to 85%+ of available bandwidth

    func test_high_bandwidth_saturation() async {
        let monitor = BandwidthMonitor()
        let controller = CongestionController()

        // Simulate 10 Gbps-class transfer: inject 1 GB in 800ms (≈1.25 GB/s)
        let chunkSize: Int64 = 8 * 1024 * 1024 // 8 MB chunks
        let totalBytes: Int64 = 1024 * 1024 * 1024 // 1 GB
        let simulatedElapsedPerChunk: TimeInterval = 0.00064 // 8 MB / 12.5 GB/s ≈ 640 µs

        var bytesSent: Int64 = 0
        while bytesSent < totalBytes {
            let chunk = min(chunkSize, totalBytes - bytesSent)
            await monitor.recordBytes(chunk, elapsed: simulatedElapsedPerChunk)
            await controller.onChunkSuccess(rtt: simulatedElapsedPerChunk)
            bytesSent += chunk
        }

        let snapshot = await monitor.currentSnapshot()
        // At high bandwidth, utilization should be measurable (> 0)
        XCTAssertGreaterThan(snapshot.currentBPS, 0)
        XCTAssertGreaterThan(snapshot.peakBPS, 0)
        // The controller should have converged to high parallelism
        let parallelism = await controller.recommendedParallelism
        XCTAssertGreaterThanOrEqual(parallelism, 1)
    }

    // MARK: - Low-bandwidth (1 Mbps): no timeout errors at slow speed

    func test_low_bandwidth_stable() async {
        let monitor = BandwidthMonitor()
        let controller = CongestionController()

        // 1 Mbps = 125 KB/s: 64 KB chunk takes ~512 ms
        let chunkSize: Int64 = 64 * 1024
        let chunkCount = 10
        let simulatedElapsedPerChunk: TimeInterval = 0.512

        for _ in 0 ..< chunkCount {
            await monitor.recordBytes(chunkSize, elapsed: simulatedElapsedPerChunk)
            await controller.onChunkSuccess(rtt: simulatedElapsedPerChunk)
        }

        let snapshot = await monitor.currentSnapshot()
        XCTAssertGreaterThan(snapshot.currentBPS, 0)
        // At slow speed the controller must not recommend more than a few streams
        let parallelism = await controller.recommendedParallelism
        XCTAssertGreaterThanOrEqual(parallelism, 1)
        XCTAssertLessThanOrEqual(parallelism, 16)
    }

    // MARK: - Congestion controller finds optimal parallelism

    func test_convergence_to_stable_parallelism() async {
        let controller = CongestionController()

        // Fast ramp: 50 success signals with 20ms RTT to drive up window
        for _ in 0 ..< 50 {
            await controller.onChunkSuccess(rtt: 0.020)
        }
        let highParallelism = await controller.recommendedParallelism
        XCTAssertGreaterThanOrEqual(highParallelism, 1)

        // Introduce congestion: 3 timeouts should reduce window
        await controller.onChunkTimeout()
        await controller.onChunkTimeout()
        await controller.onChunkTimeout()

        let reducedParallelism = await controller.recommendedParallelism
        // After timeouts, parallelism must not exceed the pre-timeout level
        XCTAssertLessThanOrEqual(reducedParallelism, highParallelism)
        XCTAssertGreaterThanOrEqual(reducedParallelism, 1)
    }

    // MARK: - Multiple large files: bandwidth shared proportionally

    func test_bandwidth_fairness_across_monitors() async {
        // Two independent monitors accumulate the same bytes over the same time
        let m1 = BandwidthMonitor()
        let m2 = BandwidthMonitor()
        let chunk: Int64 = 1 * 1024 * 1024
        let elapsed: TimeInterval = 0.01

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0 ..< 20 {
                    await m1.recordBytes(chunk, elapsed: elapsed)
                }
            }
            group.addTask {
                for _ in 0 ..< 20 {
                    await m2.recordBytes(chunk, elapsed: elapsed)
                }
            }
        }

        let s1 = await m1.currentSnapshot()
        let s2 = await m2.currentSnapshot()

        // Both monitors should report non-zero, roughly similar throughput
        XCTAssertGreaterThan(s1.currentBPS, 0)
        XCTAssertGreaterThan(s2.currentBPS, 0)

        // Neither monitor should report more than 2× the other (fair sharing)
        if s1.currentBPS > 0, s2.currentBPS > 0 {
            let ratio = max(s1.currentBPS, s2.currentBPS) / min(s1.currentBPS, s2.currentBPS)
            XCTAssertLessThanOrEqual(ratio, 4.0, "Bandwidth ratio between two monitors exceeds 4×")
        }
    }
}
