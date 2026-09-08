import XCTest
@testable import JotCore

final class MeetingExportWaitTests: XCTestCase {
    @MainActor
    func testSlowWorkWaitsBeyondTheFormerThirtySecondCutoff() async throws {
        var polls = 0
        try await MeetingExportWait.wait(isValid: { true }, isComplete: { polls == 160 }, sleep: { polls += 1 })
        XCTAssertEqual(polls, 160)
    }

    @MainActor
    func testInterruptionCannotBeMistakenForAnEmptyCompletedQueue() async {
        var valid = true
        var completed = false
        do {
            try await MeetingExportWait.wait(isValid: { valid }, isComplete: { completed }, sleep: {
                valid = false
                completed = true // Pause discards queued work.
            })
            XCTFail("An interrupted meeting must not export")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testCancellationPropagatesWithoutExporting() async {
        do {
            try await MeetingExportWait.wait(isValid: { true }, isComplete: { false }, sleep: { throw CancellationError() })
            XCTFail("Cancelled wait must not finish normally")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
