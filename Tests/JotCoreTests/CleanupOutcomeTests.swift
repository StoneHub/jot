import XCTest
@testable import JotCore

final class CleanupOutcomeTests: XCTestCase {
    @MainActor func testUnchangedAndFailedGenerationAreDistinguishableWithoutErrorContent() async {
        enum Failure: Error { case synthetic }
        let cleanup = TranscriptCleanup()
        let unchanged = await cleanup.cleanWithOutcome(["Hello."], generator: { $0 })
        XCTAssertEqual(unchanged.outcome, .unchanged)
        let failed = await cleanup.cleanWithOutcome(["Hello."], generator: { _ in throw Failure.synthetic })
        XCTAssertEqual(failed.outcome, .modelError)
        XCTAssertEqual(failed.texts, ["Hello."])
    }

    @MainActor func testRejectedEditAndWrongCountAreReported() async {
        let cleanup = TranscriptCleanup()
        let rejected = await cleanup.cleanWithOutcome(["Do not ship."], generator: { _ in ["Ship."] })
        XCTAssertEqual(rejected.outcome, .rejectedEdits)
        XCTAssertEqual(rejected.texts, ["Do not ship."])
        let invalid = await cleanup.cleanWithOutcome(["Hello."], generator: { _ in [] })
        XCTAssertEqual(invalid.outcome, .invalidCount)
    }

    @MainActor func testDeadlineIsReportedAndRawTextRetained() async {
        let result = await TranscriptCleanup().cleanWithOutcome(["original"], timeout: .milliseconds(10), generator: { _ in
            try await Task.sleep(for: .seconds(1))
            return ["late"]
        })
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.texts, ["original"])
    }
}
