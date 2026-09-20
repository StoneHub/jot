import XCTest
@testable import JotCore

final class ServiceLifecycleTests: XCTestCase {
    func testSleepResumeWaitsForWakeAndUnloadInEitherOrder() {
        for wakeFirst in [true, false] {
            var policy = SleepResumePolicy()
            policy.willSleep(ambientRunning: true, keepAwake: true)
            // Duplicate sleep notifications must not erase the interrupted capture.
            policy.willSleep(ambientRunning: false, keepAwake: true)
            if wakeFirst {
                policy.didWake()
                XCTAssertFalse(policy.takeResume(phase: .pausing))
            } else {
                XCTAssertFalse(policy.takeResume(phase: .paused))
                policy.didWake()
            }
            XCTAssertTrue(policy.takeResume(phase: .paused))
            policy.didWake()
            XCTAssertFalse(policy.takeResume(phase: .paused), "Wake must not restart capture twice")
        }
    }

    func testSleepResumeRequiresInterruptedListeningButNotKeepAwake() {
        for optedIn in [false, true] {
            var policy = SleepResumePolicy()
            policy.willSleep(ambientRunning: true, keepAwake: optedIn)
            policy.didWake()
            XCTAssertTrue(policy.takeResume(phase: .paused))
        }
        var idle = SleepResumePolicy()
        idle.willSleep(ambientRunning: false, keepAwake: true)
        idle.didWake()
        XCTAssertFalse(idle.takeResume(phase: .paused))
    }

    func testExplicitCancellationPreventsResumeEvenWhileUnloading() {
        for wakeFirst in [true, false] {
            var policy = SleepResumePolicy()
            policy.willSleep(ambientRunning: true, keepAwake: true)
            if wakeFirst { policy.didWake() }
            policy.cancel() // Explicit Pause/Stop.
            policy.didWake()
            XCTAssertFalse(policy.takeResume(phase: .paused))
            policy.willSleep(ambientRunning: true, keepAwake: true)
            policy.didWake()
            XCTAssertTrue(policy.takeResume(phase: .paused), "A later capture can opt in again")
        }
    }

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
    func testAutomaticPauseKeepsTheMeetingAndThePauseButtonEndsIt() {
        let sleep = PauseOutcome(automatic: true, ambientRequested: true, meetingTitle: "Standup")
        XCTAssertEqual(sleep, PauseOutcome(automatic: true, ambientRequested: true, meetingTitle: "Standup"))
        XCTAssertTrue(sleep.ambientRequested, "Resume restarts ambient capture after sleep")
        XCTAssertEqual(sleep.meetingTitle, "Standup")
        XCTAssertFalse(sleep.endedMeeting)
        let button = PauseOutcome(automatic: false, ambientRequested: true, meetingTitle: "Standup")
        XCTAssertFalse(button.ambientRequested)
        XCTAssertNil(button.meetingTitle)
        XCTAssertTrue(button.endedMeeting)
        XCTAssertFalse(PauseOutcome(automatic: false, ambientRequested: true, meetingTitle: nil).endedMeeting, "Plain ambient capture is not a meeting")
        XCTAssertFalse(PauseOutcome(automatic: true, ambientRequested: false, meetingTitle: nil).ambientRequested)
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
