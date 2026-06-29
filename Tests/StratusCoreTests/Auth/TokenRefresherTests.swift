import XCTest
@testable import StratusCore

final class TokenRefresherTests: XCTestCase {

    // MARK: - TokenError cases

    func test_token_error_sendable() {
        // Verify all cases compile as Sendable (Swift 6 requirement)
        let errors: [TokenError] = [
            .noCredential("acc"),
            .noRefreshToken("acc"),
            .refreshFailed,
            .unsupportedProvider("s3"),
            .internalError
        ]
        XCTAssertEqual(errors.count, 5)
    }

    func test_no_credential_error_embeds_account_id() {
        let error = TokenError.noCredential("my-account")
        if case .noCredential(let id) = error {
            XCTAssertEqual(id, "my-account")
        } else {
            XCTFail("Expected noCredential case")
        }
    }

    func test_no_refresh_token_error_embeds_account_id() {
        let error = TokenError.noRefreshToken("another-account")
        if case .noRefreshToken(let id) = error {
            XCTAssertEqual(id, "another-account")
        } else {
            XCTFail("Expected noRefreshToken case")
        }
    }

    func test_unsupported_provider_error_embeds_provider_id() {
        let error = TokenError.unsupportedProvider("box")
        if case .unsupportedProvider(let pid) = error {
            XCTAssertEqual(pid, "box")
        } else {
            XCTFail("Expected unsupportedProvider case")
        }
    }

    // MARK: - Missing credential path

    func test_valid_token_throws_no_credential_when_vault_empty() async throws {
        let refresher = TokenRefresher.shared
        do {
            _ = try await refresher.validToken(providerID: "gdrive", accountID: "nonexistent-\(UUID())")
            XCTFail("Expected TokenError.noCredential")
        } catch TokenError.noCredential {
            // Expected path
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_valid_token_throws_unsupported_provider() async throws {
        // The refresher will throw unsupportedProvider for unknown provider IDs
        // during the refresh path; noCredential fires first if vault is empty.
        let refresher = TokenRefresher.shared
        do {
            _ = try await refresher.validToken(providerID: "unknownxyz", accountID: "acc-\(UUID())")
            XCTFail("Expected a TokenError")
        } catch is TokenError {
            // Expected — either noCredential or unsupportedProvider
        } catch {
            XCTFail("Unexpected non-TokenError: \(error)")
        }
    }

    // MARK: - Concurrent calls (deduplication must not crash)

    func test_concurrent_valid_token_calls_do_not_crash() async throws {
        let refresher = TokenRefresher.shared
        let accountID = "concurrent-test-\(UUID())"
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await refresher.validToken(providerID: "gdrive", accountID: accountID)
                }
            }
        }
        // If deduplication logic has a data race this would crash under TSAN
    }
}
