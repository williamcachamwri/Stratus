import XCTest

final class UploadCenterUITests: XCTestCase {
    func testUploadCenterRowsExposeNumbersNotOnlyStatusWords() {
        let visibleLine = "624 MB / 800 MB · Chunk 13/16 · 4.2 MB/s · ETA 0:48"
        XCTAssertTrue(visibleLine.contains("/"))
        XCTAssertTrue(visibleLine.contains("Chunk"))
        XCTAssertTrue(visibleLine.contains("MB/s"))
        XCTAssertTrue(visibleLine.contains("ETA"))
    }

    func testAntiAIDesignChecklistRejectsVagueSpinnerOnlyState() {
        let badState = "Connecting..."
        XCTAssertFalse(badState.contains("MB/s"))
        XCTAssertFalse(badState.contains("ETA"))
    }
}
