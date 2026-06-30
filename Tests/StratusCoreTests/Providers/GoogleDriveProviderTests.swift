import XCTest
@testable import StratusCore

final class GoogleDriveProviderTests: XCTestCase {
    private let provider = GoogleDriveProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "gdrive")
    }

    func test_provider_display_name() {
        XCTAssertEqual(provider.displayName, "Google Drive")
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_multipart_supported() {
        XCTAssertFalse(provider.capabilities.supportsMultipartUpload)
    }

    func test_capabilities_resume_supported() {
        XCTAssertTrue(provider.capabilities.supportsResumeUpload)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_block_manifest_supported() {
        XCTAssertTrue(provider.supportsBlockManifest)
    }

    func test_capabilities_sendable() {
        func check(_: some Sendable) {}
        check(provider.capabilities)
    }

    func test_cloud_path_root_is_slash() {
        XCTAssertEqual(CloudPath("/").path, "/")
    }

    func test_cloud_path_append_and_last_component() {
        let base = CloudPath("/My Drive")
        let child = base.appendingComponent("Notes.txt")
        XCTAssertEqual(child.lastComponent, "Notes.txt")
    }

    func test_provider_capabilities_multipart_threshold() {
        XCTAssertGreaterThan(provider.capabilities.multipartThresholdBytes, 0)
    }

    func test_web_link_google_doc_opens_docs_editor() {
        let url = GoogleDriveWebLink.url(
            fileID: "doc-id",
            mimeType: "application/vnd.google-apps.document"
        )

        XCTAssertEqual(url?.absoluteString, "https://docs.google.com/document/d/doc-id/edit")
    }

    func test_web_link_google_sheet_opens_sheets_editor() {
        let url = GoogleDriveWebLink.url(
            fileID: "sheet-id",
            mimeType: "application/vnd.google-apps.spreadsheet"
        )

        XCTAssertEqual(url?.absoluteString, "https://docs.google.com/spreadsheets/d/sheet-id/edit")
    }

    func test_web_link_folder_opens_drive_folder() {
        let url = GoogleDriveWebLink.url(
            fileID: "folder-id",
            mimeType: GoogleDriveFile.folderMimeType
        )

        XCTAssertEqual(url?.absoluteString, "https://drive.google.com/drive/folders/folder-id")
    }

    func test_web_link_binary_file_opens_drive_preview() {
        let url = GoogleDriveWebLink.url(fileID: "file-id", mimeType: "application/pdf")

        XCTAssertEqual(url?.absoluteString, "https://drive.google.com/file/d/file-id/view")
    }

    func test_web_link_blank_file_id_returns_nil() {
        XCTAssertNil(GoogleDriveWebLink.url(fileID: " ", mimeType: "application/pdf"))
    }

    func test_web_link_action_title_matches_google_editor() {
        let title = GoogleDriveWebLink.actionTitle(mimeType: "application/vnd.google-apps.presentation")

        XCTAssertEqual(title, "Open in Google Slides")
    }
}
