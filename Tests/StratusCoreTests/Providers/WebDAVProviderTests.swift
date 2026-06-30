import XCTest
@testable import StratusCore

final class WebDAVProviderTests: XCTestCase {
    private let provider = WebDAVProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "webdav")
    }

    func test_provider_display_name() {
        XCTAssertFalse(provider.displayName.isEmpty)
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_capabilities_sendable() {
        func check(_: some Sendable) {}
        check(provider.capabilities)
    }

    func test_validate_credentials_without_server_config() async {
        let account = CloudAccount(id: "webdav-test", providerID: "webdav", displayName: "Test WebDAV", email: nil)
        // Without real server config this either returns false or throws
        let valid = try? await provider.validateCredentials(account: account)
        if let v = valid { XCTAssertFalse(v) }
    }

    func test_cloud_path_with_dav_path() {
        let path = CloudPath("/remote.php/webdav/Documents/file.pdf")
        XCTAssertEqual(path.lastComponent, "file.pdf")
    }
}
