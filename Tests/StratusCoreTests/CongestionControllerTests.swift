import XCTest
@testable import StratusCore

final class CongestionControllerTests: XCTestCase {

    func test_slowStartDoublesWindow() async {
        let cc = CongestionController()
        let initial = await cc.windowSizeForTesting
        await cc.onChunkSuccess(rtt: 0.05)
        let after = await cc.windowSizeForTesting
        XCTAssertEqual(after, initial * 2, accuracy: 0.001)
    }

    func test_avoidanceAddsOneOverWindow() async {
        let cc = CongestionController(maxConcurrentStreams: 100)
        // Push window above ssthresh to enter avoidance
        await cc.setWindowForTesting(33.0)
        let before = await cc.windowSizeForTesting
        await cc.onChunkSuccess(rtt: 0.05)
        let after = await cc.windowSizeForTesting
        XCTAssertEqual(after, before + 1.0 / before, accuracy: 0.001)
    }

    func test_timeoutHalvesSsthresh() async {
        let cc = CongestionController()
        await cc.setWindowForTesting(16.0)
        await cc.onChunkTimeout()
        let window = await cc.windowSizeForTesting
        let ssthresh = await cc.ssthreshForTesting
        XCTAssertEqual(window, 1.0, accuracy: 0.001)
        XCTAssertEqual(ssthresh, 8.0, accuracy: 0.001)
    }

    func test_rateLimitedHalvesWindow() async {
        let cc = CongestionController()
        await cc.setWindowForTesting(16.0)
        await cc.onChunkRateLimited(retryAfter: 1.0)
        let window = await cc.windowSizeForTesting
        XCTAssertEqual(window, 8.0, accuracy: 0.001)
    }

    func test_recommendedParallelismClampedPositive() async {
        let cc = CongestionController()
        await cc.onChunkTimeout()
        let p = await cc.recommendedParallelism
        XCTAssertGreaterThanOrEqual(p, 1)
    }

    func test_windowNeverBelowOne() async {
        let cc = CongestionController()
        for _ in 0..<10 { await cc.onChunkTimeout() }
        let window = await cc.windowSizeForTesting
        XCTAssertGreaterThanOrEqual(window, 1.0)
    }

    func test_recoveryMode_addsOnePerRTT() async {
        let cc = CongestionController(maxConcurrentStreams: 100)
        await cc.setWindowForTesting(16.0)
        await cc.onChunkRateLimited(retryAfter: 0)  // enters recovery, halves window to 8
        let before = await cc.windowSizeForTesting
        await cc.onChunkSuccess(rtt: 0.05)           // recovery: +1.0
        let after = await cc.windowSizeForTesting
        XCTAssertEqual(after, before + 1.0, accuracy: 0.001)
    }

    func test_onChunkError_halvesWindow() async {
        let cc = CongestionController(maxConcurrentStreams: 100)
        await cc.setWindowForTesting(16.0)
        await cc.onChunkError()
        let window = await cc.windowSizeForTesting
        XCTAssertEqual(window, 8.0, accuracy: 0.001)
    }

    func test_smoothedRTT_zeroInitially() async {
        let cc = CongestionController()
        let rtt = await cc.smoothedRTT
        XCTAssertEqual(rtt, 0.0)
    }

    func test_smoothedRTT_averagesLastSamples() async {
        let cc = CongestionController()
        await cc.onChunkSuccess(rtt: 0.1)
        await cc.onChunkSuccess(rtt: 0.3)
        let rtt = await cc.smoothedRTT
        XCTAssertEqual(rtt, 0.2, accuracy: 0.001)
    }

    func test_slowStart_capsAtSsthresh() async {
        let cc = CongestionController(maxConcurrentStreams: 100)
        await cc.setWindowForTesting(20.0)  // 20 < default ssthresh(32) → slowStart
        await cc.onChunkSuccess(rtt: 0.05)  // doubles to 40, capped at ssthresh(32)
        let window = await cc.windowSizeForTesting
        XCTAssertLessThanOrEqual(window, 32.0)
    }
}
