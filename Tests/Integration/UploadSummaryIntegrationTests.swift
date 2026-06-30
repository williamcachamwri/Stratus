import XCTest
@testable import StratusCore

final class UploadSummaryIntegrationTests: XCTestCase {
    func testCompletedUploadSummaryCarriesIntegrityAndThroughputFields() {
        let item = CloudFileItem(id: "remote-1", name: "video.mov", path: CloudPath("/media/video.mov"), size: 10000)
        let summary = UploadSummary(
            fileSize: 10000,
            bytesUploaded: 9000,
            bytesSkippedByDelta: 1000,
            durationSeconds: 2,
            averageBPS: 4500,
            checksumVerified: true,
            remoteItem: item
        )

        XCTAssertEqual(summary.bytesUploaded + summary.bytesSkippedByDelta, summary.fileSize)
        XCTAssertTrue(summary.checksumVerified)
        XCTAssertEqual(summary.remoteItem.path.path, "/media/video.mov")
    }
}
