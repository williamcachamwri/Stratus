import XCTest
@testable import StratusCore

final class SyncRuleTests: XCTestCase {
    // MARK: - Name scope matching

    func test_name_scope_exact_match() {
        let rule = SyncRule(type: .exclude, pattern: ".DS_Store", scope: .name)
        XCTAssertTrue(rule.matches(path: "/some/path/.DS_Store", name: ".DS_Store", fileExtension: ""))
    }

    func test_name_scope_no_match() {
        let rule = SyncRule(type: .exclude, pattern: ".DS_Store", scope: .name)
        XCTAssertFalse(rule.matches(path: "/other.txt", name: "other.txt", fileExtension: "txt"))
    }

    func test_name_scope_wildcard_tmp() {
        let rule = SyncRule(type: .exclude, pattern: "*.tmp", scope: .name)
        XCTAssertTrue(rule.matches(path: "/a/b/c.tmp", name: "c.tmp", fileExtension: "tmp"))
        XCTAssertFalse(rule.matches(path: "/a/b/c.bak", name: "c.bak", fileExtension: "bak"))
    }

    func test_name_scope_node_modules() {
        let rule = SyncRule(type: .exclude, pattern: "node_modules", scope: .name)
        XCTAssertTrue(rule.matches(path: "/project/node_modules", name: "node_modules", fileExtension: ""))
        XCTAssertFalse(rule.matches(path: "/project/src", name: "src", fileExtension: ""))
    }

    // MARK: - Extension scope matching

    func test_extension_scope_exact() {
        let rule = SyncRule(type: .exclude, pattern: "*.download", scope: .extension)
        XCTAssertTrue(rule.matches(path: "/a/b.download", name: "b.download", fileExtension: "download"))
        XCTAssertFalse(rule.matches(path: "/a/b.pdf", name: "b.pdf", fileExtension: "pdf"))
    }

    func test_extension_scope_case_insensitive() {
        let rule = SyncRule(type: .exclude, pattern: "*.part", scope: .extension)
        XCTAssertTrue(rule.matches(path: "/a/file.PART", name: "file.PART", fileExtension: "PART"))
    }

    func test_extension_scope_without_glob_prefix() {
        let rule = SyncRule(type: .exclude, pattern: "crdownload", scope: .extension)
        XCTAssertTrue(rule.matches(path: "/x.crdownload", name: "x.crdownload", fileExtension: "crdownload"))
    }

    // MARK: - Path scope matching

    func test_path_scope_matches_full_path() {
        let rule = SyncRule(type: .exclude, pattern: "/project/secrets.txt", scope: .path)
        XCTAssertTrue(rule.matches(path: "/project/secrets.txt", name: "secrets.txt", fileExtension: "txt"))
        XCTAssertFalse(rule.matches(path: "/other/secrets.txt", name: "secrets.txt", fileExtension: "txt"))
    }

    // MARK: - Size and date scopes (not matched by SyncRule directly)

    func test_size_scope_returns_false() {
        let rule = SyncRule(type: .exclude, pattern: "1024", scope: .size)
        XCTAssertFalse(rule.matches(path: "/a", name: "a", fileExtension: ""))
    }

    func test_date_scope_returns_false() {
        let rule = SyncRule(type: .exclude, pattern: "2024-01-01", scope: .date)
        XCTAssertFalse(rule.matches(path: "/a", name: "a", fileExtension: ""))
    }

    // MARK: - Default excludes

    func test_default_excludes_all_builtin() {
        let excludes = SyncRule.defaultExcludes
        XCTAssertFalse(excludes.isEmpty)
        XCTAssertTrue(excludes.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(excludes.allSatisfy { $0.type == .exclude })
    }

    func test_default_excludes_contains_ds_store() {
        let patterns = SyncRule.defaultExcludes.map(\.pattern)
        XCTAssertTrue(patterns.contains(".DS_Store"))
    }

    func test_default_excludes_contains_git() {
        let patterns = SyncRule.defaultExcludes.map(\.pattern)
        XCTAssertTrue(patterns.contains(".git"))
    }

    func test_default_excludes_contains_node_modules() {
        let patterns = SyncRule.defaultExcludes.map(\.pattern)
        XCTAssertTrue(patterns.contains("node_modules"))
    }

    // MARK: - SyncRule codable round-trip

    func test_syncrule_codable_roundtrip() throws {
        let rule = SyncRule(type: .include, pattern: "*.swift", scope: .name, recursive: false, isBuiltIn: false)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SyncRule.self, from: data)
        XCTAssertEqual(decoded.id, rule.id)
        XCTAssertEqual(decoded.type, rule.type)
        XCTAssertEqual(decoded.pattern, rule.pattern)
        XCTAssertEqual(decoded.scope, rule.scope)
        XCTAssertEqual(decoded.recursive, rule.recursive)
        XCTAssertEqual(decoded.isBuiltIn, rule.isBuiltIn)
    }

    // MARK: - SyncPair

    func test_syncpair_default_mode_is_bidirectional() {
        let pair = SyncPair(
            localPath: URL(fileURLWithPath: "/local"),
            remotePath: CloudPath("/remote"),
            accountID: "acc1"
        )
        XCTAssertEqual(pair.mode, .bidirectional)
        XCTAssertTrue(pair.enabled)
        XCTAssertEqual(pair.conflictResolution, .keepNewer)
        XCTAssertFalse(pair.rules.isEmpty)
    }

    func test_syncpair_codable_roundtrip() throws {
        let pair = SyncPair(
            localPath: URL(fileURLWithPath: "/local/docs"),
            remotePath: CloudPath("/cloud/docs"),
            accountID: "acc42",
            mode: .oneWayUpload,
            conflictResolution: .keepBoth
        )
        let data = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(SyncPair.self, from: data)
        XCTAssertEqual(decoded.id, pair.id)
        XCTAssertEqual(decoded.mode, .oneWayUpload)
        XCTAssertEqual(decoded.conflictResolution, .keepBoth)
        XCTAssertEqual(decoded.accountID, "acc42")
    }

    // MARK: - SyncMode

    func test_syncmode_all_cases_have_display_names() {
        for mode in SyncMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "SyncMode.\(mode) has empty displayName")
        }
    }

    func test_syncmode_raw_values() {
        XCTAssertEqual(SyncMode.bidirectional.rawValue, "bidirectional")
        XCTAssertEqual(SyncMode.oneWayUpload.rawValue, "one_way_upload")
        XCTAssertEqual(SyncMode.oneWayDownload.rawValue, "one_way_download")
        XCTAssertEqual(SyncMode.mirror.rawValue, "mirror")
        XCTAssertEqual(SyncMode.backup.rawValue, "backup")
    }

    // MARK: - ConflictResolution

    func test_conflictresolution_all_cases_have_display_names() {
        for cr in ConflictResolution.allCases {
            XCTAssertFalse(cr.displayName.isEmpty, "ConflictResolution.\(cr) has empty displayName")
        }
    }

    func test_conflictresolution_raw_values() {
        XCTAssertEqual(ConflictResolution.keepLocal.rawValue, "keep_local")
        XCTAssertEqual(ConflictResolution.keepRemote.rawValue, "keep_remote")
        XCTAssertEqual(ConflictResolution.keepNewer.rawValue, "keep_newer")
        XCTAssertEqual(ConflictResolution.keepLarger.rawValue, "keep_larger")
        XCTAssertEqual(ConflictResolution.keepBoth.rawValue, "keep_both")
        XCTAssertEqual(ConflictResolution.askUser.rawValue, "ask_user")
    }

    // MARK: - SyncConflict

    func test_syncconflict_initialiser_assigns_uuid() {
        let c1 = SyncConflict(
            pairID: UUID(), localURL: URL(fileURLWithPath: "/a"),
            remotePath: CloudPath("/b"),
            localModDate: Date(), remoteModDate: Date(),
            localSize: 1, remoteSize: 2
        )
        let c2 = SyncConflict(
            pairID: UUID(), localURL: URL(fileURLWithPath: "/a"),
            remotePath: CloudPath("/b"),
            localModDate: Date(), remoteModDate: Date(),
            localSize: 1, remoteSize: 2
        )
        XCTAssertNotEqual(c1.id, c2.id)
    }
}
