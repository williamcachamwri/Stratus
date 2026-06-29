import XCTest
@testable import StratusCore

final class UploadQueueTests: XCTestCase {

    func test_enqueueDequeue_respectsPriority() async {
        let queue = UploadQueue()
        let t1 = makeTask(priority: .low)
        let t2 = makeTask(priority: .high)
        let t3 = makeTask(priority: .normal)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        await queue.enqueue(t3)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, t2.id)
        let second = await queue.dequeue()
        XCTAssertEqual(second?.id, t3.id)
    }

    func test_tieBreak_smallerFileSizeWins() async {
        let queue = UploadQueue()
        let t1 = makeTask(priority: .normal, fileSize: 100_000_000)
        let t2 = makeTask(priority: .normal, fileSize: 1_000)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, t2.id)
    }

    func test_remove_correctItem() async {
        let queue = UploadQueue()
        let t1 = makeTask(priority: .normal)
        let t2 = makeTask(priority: .high)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        await queue.remove(taskID: t1.id)
        let remaining = await queue.count
        XCTAssertEqual(remaining, 1)
        let next = await queue.dequeue()
        XCTAssertEqual(next?.id, t2.id)
    }

    func test_emptyQueue_dequeueReturnsNil() async {
        let queue = UploadQueue()
        let result = await queue.dequeue()
        XCTAssertNil(result)
    }

    func test_reprioritize_rearranges() async {
        let queue = UploadQueue()
        let t1 = makeTask(priority: .low)
        let t2 = makeTask(priority: .normal)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        _ = await queue.reprioritize(taskID: t1.id, to: .critical)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, t1.id)
    }

    func test_count_matches_enqueued() async {
        let queue = UploadQueue()
        for _ in 0..<10 {
            await queue.enqueue(makeTask(priority: .normal))
        }
        let count = await queue.count
        XCTAssertEqual(count, 10)
    }

    private func makeTask(priority: TaskPriority, fileSize: Int64 = 1024) -> UploadTask {
        UploadTask(
            sourceURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin"),
            destinationPath: CloudPath("/test.bin"),
            accountID: "test",
            providerID: "test",
            fileSize: fileSize,
            localChecksum: "",
            priority: priority
        )
    }
}
