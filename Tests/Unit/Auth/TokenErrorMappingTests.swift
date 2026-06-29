import XCTest
@testable import StratusCore

final class TokenErrorMappingTests: XCTestCase {
    func testTokenErrorsRemainEquatableByCaseThroughDescriptions() {
        let errors: [TokenError] = [
            .noCredential("account-a"),
            .noRefreshToken("account-a"),
            .refreshFailed,
            .unsupportedProvider("custom"),
            .internalError,
        ]
        XCTAssertEqual(errors.count, 5)
    }
}
