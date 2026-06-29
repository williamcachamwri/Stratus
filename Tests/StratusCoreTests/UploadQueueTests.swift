import XCTest
@testable import StratusCore

final class UploadQueueTests: XCTestCase {

    func test_enqueueDequeue_respectsPriority() async {
        let queue = UploadQueue()
        let t1 = makeTask(id: "low",  priority: .low)
        let t2 = makeTask(id: "high", priority: .high)
        let t3 = makeTask(id: "norm", priority: .normal)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        await queue.enqueue(t3)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, "high")
        let second = await queue.dequeue()
        XCTAssertEqual(second?.id, "norm")
    }

    func test_tieBreak_smallerFileSizeWins() async {
        let queue = UploadQueue()
        let t1 = makeTask(id: "big",   priority: .normal, fileSize: 100_000_000)
        let t2 = makeTask(id: "small", priority: .normal, fileSize: 1_000)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, "small")
    }

    func test_remove_correctItem() async {
        let queue = UploadQueue()
        let t1 = makeTask(id: "a", priority: .normal)
        let t2 = makeTask(id: "b", priority: .high)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        await queue.remove(id: "a")
        let remaining = await queue.count
        XCTAssertEqual(remaining, 1)
        let next = await queue.dequeue()
        XCTAssertEqual(next?.id, "b")
    }

    func test_emptyQueue_dequeueReturnsNil() async {
        let queue = UploadQueue()
        let result = await queue.dequeue()
        XCTAssertNil(result)
    }

    func test_reprioritize_rearranges() async {
        let queue = UploadQueue()
        let t1 = makeTask(id: "a", priority: .low)
        let t2 = makeTask(id: "b", priority: .normal)
        await queue.enqueue(t1)
        await queue.enqueue(t2)
        await queue.reprioritize(id: "a", newPriority: .critical)
        let first = await queue.dequeue()
        XCTAssertEqual(first?.id, "a")
    }

    func test_count_matches_enqueued() async {
        let queue = UploadQueue()
        for i in 0..<10 {
            await queue.enqueue(makeTask(id: "task-\(i)", priority: .normal))
        }
        let count = await queue.count
        XCTAssertEqual(count, 10)
    }

    private func makeTask(id: String, priority: TaskPriority, fileSize: Int64 = 1024) -> UploadTask {
        UploadTask(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).bin"),
            destination: CloudPath("/\(id).bin"),
            accountID: "test",
            priority: priority,
            fileSize: fileSize
        )
    }
}
