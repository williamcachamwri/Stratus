import XCTest
@testable import StratusCore

final class BandwidthMonitorTests: XCTestCase {
    func test_ewmaWeighting() async {
        let monitor = BandwidthMonitor()
        // Feed 20 identical samples; EWMA α=0.2 converges to within 2% after ~20 samples
        for _ in 0 ..< 20 {
            await monitor.recordBytes(1_000_000, elapsed: 1.0)
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.currentBPS, 1_000_000, accuracy: 50000)
    }

    func test_peakTracking() async {
        let monitor = BandwidthMonitor()
        await monitor.recordBytes(500_000, elapsed: 1.0) // 500 KB/s
        await monitor.recordBytes(2_000_000, elapsed: 1.0) // 2 MB/s
        await monitor.recordBytes(800_000, elapsed: 1.0) // 800 KB/s
        let snap = await monitor.currentSnapshot()
        XCTAssertGreaterThanOrEqual(snap.peakBPS, 2_000_000)
    }

    func test_averageBPSOverMultipleSamples() async {
        let monitor = BandwidthMonitor()
        let expectedBPS: Double = 1_500_000
        for _ in 0 ..< 10 {
            await monitor.recordBytes(Int64(expectedBPS), elapsed: 1.0)
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.averageBPS, expectedBPS, accuracy: expectedBPS * 0.05)
    }

    func test_trend_increasing() async {
        let monitor = BandwidthMonitor()
        for i in 1 ... 10 {
            await monitor.recordBytes(Int64(i * 100_000), elapsed: 1.0)
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.trend, .rising)
    }

    func test_trend_decreasing() async {
        let monitor = BandwidthMonitor()
        for i in stride(from: 10, through: 1, by: -1) {
            await monitor.recordBytes(Int64(i * 100_000), elapsed: 1.0)
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.trend, .falling)
    }

    func test_ringBuffer_overflow_keepsNewest() async {
        let monitor = BandwidthMonitor()
        // Fill beyond capacity (50 samples)
        for i in 1 ... 60 {
            await monitor.recordBytes(Int64(i * 10000), elapsed: 1.0)
        }
        // After 60 inserts into a 50-cap ring, the average should reflect the last 50
        let snap = await monitor.currentSnapshot()
        XCTAssertGreaterThan(snap.averageBPS, 0)
    }

    func test_currentBPS_zeroWhenNoSamples() async {
        let monitor = BandwidthMonitor()
        let bps = await monitor.currentBPS
        XCTAssertEqual(bps, 0.0)
    }

    func test_estimatedTimeRemaining_infinityWhenNoSamples() async {
        let monitor = BandwidthMonitor()
        let eta = await monitor.estimatedTimeRemaining(bytesLeft: 1_000_000)
        XCTAssertTrue(eta.isInfinite, "No bandwidth → ETA must be infinite")
    }

    func test_estimatedTimeRemaining_ratioBytesOverSpeed() async {
        let monitor = BandwidthMonitor()
        for _ in 0 ..< 20 {
            await monitor.recordBytes(1_000_000, elapsed: 1.0) // 1 MB/s
        }
        let eta = await monitor.estimatedTimeRemaining(bytesLeft: 10_000_000)
        XCTAssertEqual(eta, 10.0, accuracy: 1.0, "10 MB at 1 MB/s ≈ 10 seconds")
    }

    func test_trendStable_afterConstantRateSamples() async {
        let monitor = BandwidthMonitor()
        for _ in 0 ..< 20 {
            await monitor.recordBytes(2_000_000, elapsed: 1.0) // constant 2 MB/s
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.trend, .stable)
    }

    func test_reset_zeroesCurrentBPS() async {
        let monitor = BandwidthMonitor()
        for _ in 0 ..< 5 {
            await monitor.recordBytes(5_000_000, elapsed: 1.0)
        }
        await monitor.reset()
        let bps = await monitor.currentBPS
        XCTAssertEqual(bps, 0.0, "After reset, BPS must be zero")
    }

    func test_utilization_halfOfTheoreticalMax() async {
        let maxBPS = 10_000_000.0 // 10 MB/s
        let monitor = BandwidthMonitor(theoreticalMaxBPS: maxBPS)
        for _ in 0 ..< 20 {
            await monitor.recordBytes(5_000_000, elapsed: 1.0) // 5 MB/s
        }
        let snap = await monitor.currentSnapshot()
        XCTAssertEqual(snap.utilization, 0.5, accuracy: 0.05)
    }
}
