import XCTest
@testable import StratusCore

final class CongestionControllerTests: XCTestCase {

    func test_slowStartDoublesWindow() async {
        let cc = CongestionController()
        let initial = await cc.windowSize
        await cc.onChunkSuccess(rtt: 0.05)
        let after = await cc.windowSize
        XCTAssertEqual(after, initial * 2, accuracy: 0.001)
    }

    func test_avoidanceAddsOneOverWindow() async {
        let cc = CongestionController()
        // Push window above ssthresh to enter avoidance
        await cc.setWindowForTesting(33.0)
        let before = await cc.windowSize
        await cc.onChunkSuccess(rtt: 0.05)
        let after = await cc.windowSize
        XCTAssertEqual(after, before + 1.0 / before, accuracy: 0.001)
    }

    func test_timeoutHalvesSsthresh() async {
        let cc = CongestionController()
        await cc.setWindowForTesting(16.0)
        await cc.onChunkTimeout()
        let window = await cc.windowSize
        let ssthresh = await cc.ssthresh
        XCTAssertEqual(window, 1.0, accuracy: 0.001)
        XCTAssertEqual(ssthresh, 8.0, accuracy: 0.001)
    }

    func test_rateLimitedHalvesWindow() async {
        let cc = CongestionController()
        await cc.setWindowForTesting(16.0)
        await cc.onChunkRateLimited(retryAfter: 1.0)
        let window = await cc.windowSize
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
        let window = await cc.windowSize
        XCTAssertGreaterThanOrEqual(window, 1.0)
    }
}
