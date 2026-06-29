import XCTest
@testable import StratusCore

final class SyncRuleDefaultExcludesTests: XCTestCase {
    func testDefaultRulesExcludeCommonLocalNoise() {
        let names = Set(SyncRule.defaultExcludes.map(\.pattern))
        XCTAssertTrue(names.contains(".DS_Store"))
        XCTAssertTrue(names.contains(".git"))
        XCTAssertTrue(names.contains("node_modules"))
        XCTAssertTrue(names.contains("__pycache__"))
    }

    func testTmpFileExtensionRuleMatchesCaseInsensitiveExtension() {
        let rule = SyncRule(type: .exclude, pattern: "*.tmp", scope: .extension)
        XCTAssertTrue(rule.matches(path: "/Users/me/file.TMP", name: "file.TMP", fileExtension: "TMP"))
    }
}
