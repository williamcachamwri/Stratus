import XCTest
@testable import StratusCore

final class DropboxProviderTests: XCTestCase {

    private let provider = DropboxProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "dropbox")
    }

    func test_provider_display_name() {
        XCTAssertFalse(provider.displayName.isEmpty)
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_multipart_supported() {
        XCTAssertTrue(provider.capabilities.supportsMultipartUpload)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_block_manifest_not_supported() {
        XCTAssertFalse(provider.supportsBlockManifest)
    }

    func test_capabilities_sendable() {
        func check<T: Sendable>(_: T) {}
        check(provider.capabilities)
    }

    func test_cloud_path_last_component_for_file() {
        let path = CloudPath("/Apps/Stratus/backup.zip")
        XCTAssertEqual(path.lastComponent, "backup.zip")
    }

    func test_cloud_path_deleting_last_component() {
        let path = CloudPath("/Apps/Stratus/backup.zip")
        XCTAssertEqual(path.deletingLastComponent.path, "/Apps/Stratus")
    }
}
