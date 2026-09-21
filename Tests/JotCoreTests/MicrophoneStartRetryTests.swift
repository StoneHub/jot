import XCTest
@testable import JotCore

final class MicrophoneStartRetryTests: XCTestCase {
    func testDelaysGrowThenStop() {
        let retry = MicrophoneStartRetry()
        XCTAssertEqual((1...5).map { retry.delay(afterFailedAttempt: $0) }, [1, 2, 4, 8, 15])
        XCTAssertNil(retry.delay(afterFailedAttempt: 6))
        XCTAssertEqual(retry.attempts, 6)
    }

    func testOutOfRangeAttemptsNeverRetry() {
        let retry = MicrophoneStartRetry(delays: [3])
        XCTAssertNil(retry.delay(afterFailedAttempt: 0))
        XCTAssertEqual(retry.delay(afterFailedAttempt: 1), 3)
        XCTAssertNil(retry.delay(afterFailedAttempt: 2))
    }
}
