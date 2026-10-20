import XCTest
@testable import JotCore

final class VorssaintFeatureTests: XCTestCase {
    private func controls(mode: String = "paused", meeting: Bool = false, dictation: DictationAttempt.State? = nil,
                          dictationSequence: UInt64 = 0, suggestion: String = "idle", suggestionSequence: Int = 0) -> ControlSnapshot {
        ControlSnapshot(mode: mode, meetingActive: meeting, dictation: dictation, dictationSequence: dictationSequence,
                        suggestion: suggestion, suggestionSequence: suggestionSequence, inputLevel: 0.25)
    }

    func testListeningSwitchFollowsModeAndMeeting() {
        var presentation = VorssaintPresentation()
        for (mode, meeting, on) in [("paused", false, false), ("pausing", false, false), ("starting", false, true),
                                    ("ambient", false, true), ("dictation", false, true), ("paused", true, true)] {
            let reply = presentation.reply(controls(mode: mode, meeting: meeting), process: 1)
            XCTAssertEqual(reply["toggleValues"] as? [String: Bool], ["listening": on], mode)
            let actions = reply["enabledActions"] as? [String] ?? []
            XCTAssertTrue(actions.contains(on ? "pause" : "listen"), mode)
            XCTAssertTrue(actions.contains(meeting ? "meeting.end" : "meeting.start"), mode)
        }
    }

    func testActionsSettleOnlyOnceJotShowsTheRequestedState() {
        XCTAssertFalse(VorssaintPresentation.settled(after: "pause", controls(mode: "ambient")))
        XCTAssertFalse(VorssaintPresentation.settled(after: "pause", controls(mode: "pausing")),
                       "Pausing still saves speech and unloads models")
        XCTAssertTrue(VorssaintPresentation.settled(after: "pause", controls(mode: "paused")))
        XCTAssertTrue(VorssaintPresentation.settled(after: "pause", controls(mode: "failed")))
        XCTAssertFalse(VorssaintPresentation.settled(after: "pause", controls(mode: "paused", meeting: true)))
        XCTAssertFalse(VorssaintPresentation.settled(after: "listen", controls(mode: "paused")))
        XCTAssertTrue(VorssaintPresentation.settled(after: "listen", controls(mode: "starting")))
        XCTAssertTrue(VorssaintPresentation.settled(after: "meeting.start", controls(mode: "ambient", meeting: true)))
        XCTAssertFalse(VorssaintPresentation.settled(after: "meeting.end", controls(mode: "ambient", meeting: true)))
        XCTAssertTrue(VorssaintPresentation.settled(after: "open", controls()))
    }

    func testOnlyConfirmedInsertionReadsAsDone() {
        var presentation = VorssaintPresentation()
        _ = presentation.reply(controls(mode: "ambient"), process: 1)
        let unverified = presentation.reply(controls(mode: "ambient", dictation: .deliveryUnverified, dictationSequence: 1), process: 1)
        XCTAssertEqual(unverified["phase"] as? String, "review")
        let delivered = presentation.reply(controls(mode: "ambient", dictation: .delivered, dictationSequence: 2), process: 1)
        XCTAssertEqual(delivered["phase"] as? String, "completed")
        XCTAssertEqual(delivered["status"] as? String, "Inserted")
    }

    func testFirstSnapshotDoesNotReplayAnOldResult() {
        var presentation = VorssaintPresentation()
        let reply = presentation.reply(controls(mode: "ambient", dictation: .delivered, dictationSequence: 9), process: 1)
        XCTAssertEqual(reply["phase"] as? String, "idle")
    }

    func testNewJotProcessStartsNewInstance() {
        var presentation = VorssaintPresentation()
        let first = presentation.reply(controls(), process: 1)["instance"] as? String
        XCTAssertEqual(presentation.reply(controls(), process: 1)["instance"] as? String, first)
        XCTAssertNotEqual(presentation.reply(controls(), process: 2)["instance"] as? String, first)
    }

    func testRepliesCarryNoTextFromJot() {
        var presentation = VorssaintPresentation()
        let reply = presentation.reply(controls(mode: "ambient", meeting: true), process: 1)
        XCTAssertEqual(Set(reply.keys), ["version", "instance", "status", "phase", "level", "toggleValues", "enabledActions"])
    }
}
