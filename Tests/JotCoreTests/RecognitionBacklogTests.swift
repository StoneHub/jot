import JotCore
import XCTest

final class RecognitionBacklogTests: XCTestCase {
    /// Chunks fill the budget, final or not; the first one past it opens a gap that every later one lengthens.
    func testFullQueueWithholdsAndCountsOneGap() {
        var backlog = RecognitionBacklog(budgetSeconds: 10, headroomSeconds: 4)
        XCTAssertEqual(backlog.offer(seconds: 3, queuedSeconds: 6), .queue(endedGapSeconds: nil))
        XCTAssertEqual(backlog.offer(seconds: 3, queuedSeconds: 9), .withhold(began: true))
        XCTAssertEqual(backlog.offer(seconds: 2, queuedSeconds: 9), .withhold(began: false))
        XCTAssertTrue(backlog.isFull)
        XCTAssertEqual(backlog.gapSeconds, 5)
    }

    /// Audio is taken again only once the queue is a headroom below the budget, and that chunk reports the gap's length.
    func testGapEndsBelowTheHeadroom() {
        var backlog = RecognitionBacklog(budgetSeconds: 10, headroomSeconds: 4)
        _ = backlog.offer(seconds: 3, queuedSeconds: 9)
        XCTAssertEqual(backlog.offer(seconds: 3, queuedSeconds: 5), .withhold(began: false))
        XCTAssertEqual(backlog.offer(seconds: 3, queuedSeconds: 3), .queue(endedGapSeconds: 6))
        XCTAssertFalse(backlog.isFull)
        XCTAssertNil(backlog.gapSeconds)
        XCTAssertEqual(backlog.offer(seconds: 3, queuedSeconds: 6), .queue(endedGapSeconds: nil))
    }

    /// A session end closes the gap once; nothing is open afterwards.
    func testCloseReportsTheOpenGapOnce() {
        var backlog = RecognitionBacklog(budgetSeconds: 10, headroomSeconds: 4)
        XCTAssertNil(backlog.close())
        _ = backlog.offer(seconds: 3, queuedSeconds: 9)
        _ = backlog.offer(seconds: 3, queuedSeconds: 9)
        XCTAssertEqual(backlog.close(), 6)
        XCTAssertNil(backlog.close())
        XCTAssertFalse(backlog.isFull)
    }

    /// The defaults bound a hung recognizer at ten minutes, and the headroom never exceeds the budget.
    func testDefaultsAndClamping() {
        let backlog = RecognitionBacklog()
        XCTAssertEqual(backlog.budgetSeconds, 600)
        XCTAssertEqual(backlog.headroomSeconds, 30)
        let tiny = RecognitionBacklog(budgetSeconds: 5, headroomSeconds: 50)
        XCTAssertEqual(tiny.headroomSeconds, 5)
    }
}
