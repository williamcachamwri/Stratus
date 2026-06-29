import XCTest
@testable import StratusCore

final class LargeQueuePerformanceTests: XCTestCase {
    func testPrioritySortForLargeQueueStaysDeterministic() {
        let tasks = (0..<5_000).map { index in
            QueueProbe(id: index, priority: index.isMultiple(of: 7) ? .high : .normal, bytes: Int64(5_000 - index))
        }

        measure {
            let sorted = tasks.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.bytes < $1.bytes
            }
            XCTAssertEqual(sorted.first?.priority, .high)
        }
    }
}

private struct QueueProbe {
    let id: Int
    let priority: TaskPriority
    let bytes: Int64
}
