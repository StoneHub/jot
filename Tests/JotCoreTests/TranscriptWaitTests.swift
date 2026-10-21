import XCTest
@testable import JotCore

final class TranscriptWaitTests: XCTestCase {
    /// Pages handed out in order, a clock that only moves when the wait sleeps, and the positions each read asked for.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [TranscriptChanges]
        private(set) var clock = 0.0
        private(set) var reads: [(Int64?, String?)] = []
        private(set) var sleeps: [Double] = []
        init(_ pages: [TranscriptChanges]) { self.pages = pages }
        func now() -> Double { lock.withLock { clock } }
        func read(_ cursor: Int64?, _ generation: String?) -> TranscriptChanges {
            lock.withLock {
                reads.append((cursor, generation))
                return pages.count > 1 ? pages.removeFirst() : pages[0]
            }
        }
        func sleep(_ seconds: Double) { lock.withLock { sleeps.append(seconds); clock += seconds } }
    }

    private func row(_ id: String, sequence: Int64) -> TranscriptChange {
        TranscriptChange(Transcript(id: id, sessionID: "s1", startedAt: Date(timeIntervalSince1970: 0), startSeconds: 0, endSeconds: 1, text: "hello", mode: "ambient"), sequence: sequence)
    }
    private func empty(_ cursor: Int64, hasMore: Bool = false) -> TranscriptChanges {
        TranscriptChanges(rows: [], cursor: cursor, hasMore: hasMore, generation: "g")
    }
    private func wait(_ feed: Feed, cursor: Int64? = nil, generation: String? = nil, timeout: Int) async throws -> TranscriptWait.Outcome {
        try await TranscriptWait.run(cursor: cursor, generation: generation, timeout: timeout, now: { feed.now() },
                                     read: { feed.read($0, $1) }, sleep: { feed.sleep($0) })
    }

    func testOmittedCursorSubscribesAtTheHeadAndReturnsTheFirstChange() async throws {
        let change = TranscriptChanges(rows: [row("a", sequence: 13)], cursor: 13, hasMore: false, generation: "g")
        let feed = Feed([empty(12), empty(12), change])
        let outcome = try await wait(feed, timeout: 30)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.page, change)
        // The first read subscribes at the head; later reads follow from it with its generation.
        XCTAssertEqual(feed.reads.map { $0.0 }, [nil, 12, 12])
        XCTAssertEqual(feed.reads.map { $0.1 }, [nil, "g", "g"])
        XCTAssertEqual(feed.sleeps, [TranscriptWait.pollSeconds, TranscriptWait.pollSeconds])
    }

    func testTimesOutWithTheCursorToResumeFrom() async throws {
        // A session filter advances the cursor over other sessions' changes without returning rows.
        let feed = Feed([empty(5), empty(9)])
        let outcome = try await wait(feed, cursor: 5, generation: "g", timeout: 2)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.page.cursor, 9)
        XCTAssertEqual(feed.reads.last?.0, 9)
        XCTAssertEqual(feed.clock, 2, accuracy: 0.001)
    }

    func testZeroTimeoutReadsOnceAndDoesNotSleep() async throws {
        let feed = Feed([empty(4)])
        let outcome = try await wait(feed, cursor: 4, timeout: 0)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(feed.reads.count, 1)
        XCTAssertEqual(feed.sleeps, [])
    }

    func testDeletionsAndResetsReturnAtOnce() async throws {
        let deleted = TranscriptChanges(rows: [], cursor: 8, hasMore: false, deleted: [TranscriptDeletion(id: "a", sessionID: "s1", sequence: 8)], generation: "g")
        var outcome = try await wait(Feed([deleted]), cursor: 7, timeout: 30)
        XCTAssertFalse(outcome.timedOut); XCTAssertEqual(outcome.page, deleted)
        let reset = TranscriptChanges(rows: [], cursor: 0, hasMore: false, reset: true, generation: "new")
        outcome = try await wait(Feed([reset]), cursor: 7, generation: "old", timeout: 30)
        XCTAssertFalse(outcome.timedOut); XCTAssertTrue(outcome.page.reset)
    }

    func testFilteredPagesWithMoreToReadDoNotSleep() async throws {
        let change = TranscriptChanges(rows: [row("b", sequence: 400)], cursor: 400, hasMore: false, generation: "g")
        let feed = Feed([empty(200, hasMore: true), empty(399, hasMore: true), change])
        let outcome = try await wait(feed, cursor: 0, timeout: 30)
        XCTAssertEqual(outcome.page, change)
        XCTAssertEqual(feed.reads.map { $0.0 }, [0, 200, 399])
        XCTAssertEqual(feed.sleeps, [])
    }

    func testTimeoutArgumentIsBounded() throws {
        XCTAssertEqual(try TranscriptWait.timeout([:]), TranscriptWait.defaultTimeoutSeconds)
        XCTAssertEqual(try TranscriptWait.timeout(["timeoutSeconds": 0]), 0)
        XCTAssertEqual(try TranscriptWait.timeout(["timeoutSeconds": TranscriptWait.maximumTimeoutSeconds]), TranscriptWait.maximumTimeoutSeconds)
        for bad in [TranscriptWait.maximumTimeoutSeconds + 1, -1, "5", 1.5] as [Any] {
            XCTAssertThrowsError(try TranscriptWait.timeout(["timeoutSeconds": bad]))
        }
    }
}
