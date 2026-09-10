import XCTest
@testable import JotCore

final class ServiceLifecycleTests: XCTestCase {
    func testJotInputSelectionNotificationsAreBrieflyIgnored() {
        var filter = AudioConfigurationChangeFilter()
        XCTAssertFalse(filter.shouldIgnore(at: 10))
        filter.expectSelectionChange(at: 10, duration: 1)
        XCTAssertTrue(filter.shouldIgnore(at: 10.1))
        XCTAssertTrue(filter.shouldIgnore(at: 10.9), "One input selection can emit more than one notification")
        XCTAssertFalse(filter.shouldIgnore(at: 11.1), "Later hardware changes must still pause capture")
    }

    func testPauseDuringModelLoadRejectsLateReady() throws {
        var lifecycle = ServiceLifecycle()
        let load = try XCTUnwrap(lifecycle.beginStart())
        let pause = try XCTUnwrap(lifecycle.beginPause())
        XCTAssertFalse(lifecycle.finishStart(load, succeeded: true))
        XCTAssertNil(lifecycle.beginStart(), "Do not overlap unloading and reloading")
        XCTAssertTrue(lifecycle.finishPause(pause))
        XCTAssertEqual(lifecycle.phase, .paused)
    }
    func testOldInferenceCannotWriteAfterPauseAndResume() throws {
        var lifecycle = ServiceLifecycle()
        let first = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.finishStart(first, succeeded: true))
        XCTAssertTrue(lifecycle.acceptsWork(first))
        let pause = try XCTUnwrap(lifecycle.beginPause())
        XCTAssertFalse(lifecycle.acceptsWork(first))
        XCTAssertTrue(lifecycle.finishPause(pause))
        let second = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.finishStart(second, succeeded: true))
        XCTAssertFalse(lifecycle.acceptsWork(first))
        XCTAssertTrue(lifecycle.acceptsWork(second))
        XCTAssertFalse(lifecycle.finishPause(pause))
    }
    func testPauseIsIdempotentAndFailedLoadCanRetry() throws {
        var lifecycle = ServiceLifecycle()
        XCTAssertNil(lifecycle.beginPause())
        let first = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertNil(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.finishStart(first, succeeded: false))
        XCTAssertNotNil(lifecycle.beginStart())
        XCTAssertNotNil(lifecycle.beginPause())
        XCTAssertNil(lifecycle.beginPause())
    }
}
