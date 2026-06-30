import XCTest
@testable import StratusCore

final class ChangeJournalTests: XCTestCase {
    // MARK: - ChangeEvent

    func test_change_event_unique_ids() {
        let pairID = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let e1 = ChangeEvent(pairID: pairID, localURL: url, changeType: .created)
        let e2 = ChangeEvent(pairID: pairID, localURL: url, changeType: .created)
        XCTAssertNotEqual(e1.id, e2.id, "Each ChangeEvent must have a unique ID")
    }

    func test_change_event_stores_fields() {
        let pairID = UUID()
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        let renamed = URL(fileURLWithPath: "/tmp/old.pdf")
        let event = ChangeEvent(pairID: pairID, localURL: url, changeType: .renamed, renamedFrom: renamed)
        XCTAssertEqual(event.pairID, pairID)
        XCTAssertEqual(event.localURL, url)
        XCTAssertEqual(event.changeType, .renamed)
        XCTAssertEqual(event.renamedFrom, renamed)
    }

    func test_change_event_default_renamed_from_nil() {
        let event = ChangeEvent(pairID: UUID(), localURL: URL(fileURLWithPath: "/a"), changeType: .modified)
        XCTAssertNil(event.renamedFrom)
    }

    func test_change_event_detected_at_is_recent() {
        let before = Date()
        let event = ChangeEvent(pairID: UUID(), localURL: URL(fileURLWithPath: "/b"), changeType: .deleted)
        let after = Date()
        XCTAssertTrue(event.detectedAt >= before)
        XCTAssertTrue(event.detectedAt <= after)
    }

    // MARK: - ChangeType

    func test_changetype_raw_values() {
        XCTAssertEqual(ChangeType.created.rawValue, "created")
        XCTAssertEqual(ChangeType.modified.rawValue, "modified")
        XCTAssertEqual(ChangeType.deleted.rawValue, "deleted")
        XCTAssertEqual(ChangeType.renamed.rawValue, "renamed")
        XCTAssertEqual(ChangeType.moved.rawValue, "moved")
    }

    // MARK: - ChangeJournal actor

    func test_start_and_stop_watching_does_not_crash() async {
        let journal = ChangeJournal.shared
        let pair = SyncPair(
            localPath: URL(fileURLWithPath: "/tmp"),
            remotePath: CloudPath("/remote"),
            accountID: "acc1"
        )
        await journal.startWatching(pair: pair)
        await journal.stopWatching(pairID: pair.id)
    }

    func test_stop_watching_nonexistent_pair_is_noop() async {
        let journal = ChangeJournal.shared
        // Stopping a pair that was never started must not crash
        await journal.stopWatching(pairID: UUID())
    }

    func test_events_stream_terminates_on_stop() async {
        let journal = ChangeJournal.shared
        let pair = SyncPair(
            localPath: URL(fileURLWithPath: "/tmp"),
            remotePath: CloudPath("/remote/test"),
            accountID: "stream-test"
        )
        await journal.startWatching(pair: pair)
        let stream = await journal.events(for: pair.id)
        // Stop watching — the stream should stop yielding new events
        await journal.stopWatching(pairID: pair.id)
        // Simply consuming with a timeout proves no deadlock
        let result = await withTimeoutOrNil(seconds: 0.5) {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 100 { break }
            }
            return count
        }
        XCTAssertNotNil(result) // Did not deadlock
    }

    func test_double_start_watching_is_idempotent() async {
        let journal = ChangeJournal.shared
        let pair = SyncPair(
            localPath: URL(fileURLWithPath: "/tmp"),
            remotePath: CloudPath("/remote/idempotent"),
            accountID: "idempotent-acc"
        )
        await journal.startWatching(pair: pair)
        await journal.startWatching(pair: pair) // second call must be safe
        await journal.stopWatching(pairID: pair.id)
    }
}

// MARK: - Helpers

private func withTimeoutOrNil<T: Sendable>(seconds: TimeInterval, work: @Sendable @escaping () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}
