import XCTest
@testable import StratusCore

final class UploadSummaryIntegrationTests: XCTestCase {
    func testCompletedUploadSummaryCarriesIntegrityAndThroughputFields() {
        let item = CloudFileItem(id: "remote-1", name: "video.mov", path: CloudPath("/media/video.mov"), size: 10_000)
        let summary = UploadSummary(
            fileSize: 10_000,
            bytesUploaded: 9_000,
            bytesSkippedByDelta: 1_000,
            durationSeconds: 2,
            averageBPS: 4_500,
            checksumVerified: true,
            remoteItem: item
        )

        XCTAssertEqual(summary.bytesUploaded + summary.bytesSkippedByDelta, summary.fileSize)
        XCTAssertTrue(summary.checksumVerified)
        XCTAssertEqual(summary.remoteItem.path.path, "/media/video.mov")
    }
}
