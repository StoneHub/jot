import XCTest
@testable import JotCore

final class SessionSplitTests: XCTestCase {
    func testQuietEndsAnAmbientSessionOnlyWhenNothingIsPending() {
        XCTAssertTrue(SessionSplit.shouldStart(silenceMinutes: 15, silenceSeconds: 900, isMeeting: false, workPending: false))
        XCTAssertFalse(SessionSplit.shouldStart(silenceMinutes: 15, silenceSeconds: 899, isMeeting: false, workPending: false))
        XCTAssertFalse(SessionSplit.shouldStart(silenceMinutes: 15, silenceSeconds: 5000, isMeeting: true, workPending: false), "A named meeting runs until it is ended")
        XCTAssertFalse(SessionSplit.shouldStart(silenceMinutes: 15, silenceSeconds: 5000, isMeeting: false, workPending: true), "Queued audio still belongs to this session")
        XCTAssertFalse(SessionSplit.shouldStart(silenceMinutes: 0, silenceSeconds: 5000, isMeeting: false, workPending: false), "Never means one session per capture")
    }

    func testLabelsReadAsMenuItems() {
        XCTAssertEqual(SessionSplit.label(0), "Never")
        XCTAssertEqual(SessionSplit.label(15), "15 minutes")
        XCTAssertEqual(SessionSplit.choices.first, 0)
        XCTAssertTrue(SessionSplit.choices.contains(SessionSplit.defaultMinutes))
    }
}
