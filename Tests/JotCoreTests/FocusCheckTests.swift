import XCTest
@testable import JotCore

@MainActor
final class FocusCheckTests: XCTestCase {
    /// Replays a fixed series of reads and counts the reads and waits the check made.
    @MainActor private final class Reads {
        var answers: [FocusCheck]
        var reads = 0
        var waits = 0
        init(_ answers: [FocusCheck]) { self.answers = answers }

        func settle(attempts: Int) async throws -> FocusCheck {
            try await FocusCheck.settle(attempts: attempts, wait: { self.waits += 1 }, read: {
                self.reads += 1
                return self.answers.isEmpty ? .noAnswer : self.answers.removeFirst()
            })
        }
    }

    func testAnswerOnFirstReadDoesNotWait() async throws {
        for answer in [FocusCheck.current, .moved] {
            let reads = Reads([answer])
            let result = try await reads.settle(attempts: 20)
            XCTAssertEqual(result, answer)
            XCTAssertEqual(reads.reads, 1)
            XCTAssertEqual(reads.waits, 0)
        }
    }

    /// Safari's web content goes quiet while it lays out text Jot just wrote; a later answer keeps the field.
    func testBusyAppThatAnswersKeepsTheField() async throws {
        let reads = Reads([.noAnswer, .noAnswer, .noAnswer, .current])
        let result = try await reads.settle(attempts: 20)
        XCTAssertEqual(result, .current)
        XCTAssertEqual(reads.reads, 4)
        XCTAssertEqual(reads.waits, 3)
    }

    /// A late answer naming another element still ends the delivery.
    func testLateAnswerThatFocusMovedIsKept() async throws {
        let reads = Reads([.noAnswer, .moved, .current])
        let result = try await reads.settle(attempts: 20)
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(reads.reads, 2)
    }

    /// An app that never answers is never treated as still focused.
    func testSilenceIsBoundedAndNeverCurrent() async throws {
        let reads = Reads([])
        let result = try await reads.settle(attempts: 5)
        XCTAssertEqual(result, .noAnswer)
        XCTAssertEqual(reads.reads, 5)
        XCTAssertEqual(reads.waits, 4)
    }

    func testThrownReadOrWaitEndsTheCheck() async {
        struct Refused: Error {}
        do {
            _ = try await FocusCheck.settle(attempts: 5, wait: {}, read: { throw Refused() })
            XCTFail("A read that throws must end the check")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        var reads = 0
        do {
            _ = try await FocusCheck.settle(attempts: 5, wait: { throw CancellationError() }, read: {
                reads += 1
                return .noAnswer
            })
            XCTFail("A cancelled wait must end the check")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(reads, 1)
    }
}
