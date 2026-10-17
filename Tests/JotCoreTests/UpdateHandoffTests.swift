import XCTest
@testable import JotCore

/// The handoff an update leaves for the relaunch, and the resume a failed update gives back. Each test uses its own
/// in-memory preferences.
final class UpdateHandoffTests: XCTestCase {
    /// What the closures saw. A main-actor class, so the escaping closures can share it.
    @MainActor private final class Probe {
        var drained = false
        var resumed = false
        var resumedAfterDrain: Bool?
    }

    /// XCTest makes a fresh instance for each test, so each gets its own preferences.
    private let defaults = MemoryDefaults()

    @MainActor
    func testListeningUpdateResumesAtRelaunchWithItsMeeting() {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: true)
        handoff.commit(meetingTitle: "Standup")
        XCTAssertFalse(defaults.bool(forKey: JotDefaultsKey.servicePaused))
        XCTAssertEqual(UpdateHandoff(defaults: defaults).takeMeetingTitle(), "Standup")
        XCTAssertNil(defaults.string(forKey: JotDefaultsKey.updateMeetingTitle), "A later plain relaunch must not rename a session")
    }

    @MainActor
    func testListeningWithoutAMeetingLeavesNoTitle() {
        defaults.set("Old meeting", forKey: JotDefaultsKey.updateMeetingTitle)
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: true)
        handoff.commit(meetingTitle: nil)
        XCTAssertFalse(defaults.bool(forKey: JotDefaultsKey.servicePaused))
        XCTAssertNil(handoff.takeMeetingTitle())
    }

    @MainActor
    func testPausedUpdateStaysPausedAndDropsTheMeeting() {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: false)
        handoff.commit(meetingTitle: "Standup")
        XCTAssertTrue(defaults.bool(forKey: JotDefaultsKey.servicePaused), "Updating a paused app would start capture at relaunch")
        XCTAssertNil(handoff.takeMeetingTitle())
    }

    @MainActor
    func testFailedUpdateResumesListeningAfterPauseSettles() async {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: true)
        handoff.commit(meetingTitle: "Standup")
        let probe = Probe()
        let pausing = Task { @MainActor in await Task.yield(); probe.drained = true }
        handoff.cancel(after: { pausing }, stillWanted: { true }, resume: { probe.resumedAfterDrain = probe.drained })
        XCTAssertNil(defaults.string(forKey: JotDefaultsKey.updateMeetingTitle), "A failed update hands nothing to a relaunch")
        await handoff.waitForRecovery()
        XCTAssertEqual(probe.resumedAfterDrain, true)
    }

    @MainActor
    func testFailedUpdateOfAPausedAppResumesNothing() async {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: false)
        let probe = Probe()
        handoff.cancel(after: { nil }, stillWanted: { true }, resume: { probe.resumed = true })
        await handoff.waitForRecovery()
        XCTAssertFalse(probe.resumed)
    }

    @MainActor
    func testListeningNoLongerWantedIsNotResumed() async {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: true)
        let probe = Probe()
        handoff.cancel(after: { nil }, stillWanted: { false }, resume: { probe.resumed = true })
        await handoff.waitForRecovery()
        XCTAssertFalse(probe.resumed)
    }

    @MainActor
    func testExplicitPauseCancelsTheResume() async {
        let handoff = UpdateHandoff(defaults: defaults)
        handoff.begin(listening: true)
        let probe = Probe()
        let pausing = Task { @MainActor in await Task.yield() }
        handoff.cancel(after: { pausing }, stillWanted: { true }, resume: { probe.resumed = true })
        handoff.cancelRecovery()
        await pausing.value
        await Task.yield()
        XCTAssertFalse(probe.resumed)
    }
}
