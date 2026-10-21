import XCTest
@testable import JotCore

final class VorssaintFeatureTests: XCTestCase {
    private func controls(mode: String = "paused", meeting: Bool = false, dictation: DictationAttempt.State? = nil,
                          dictationSequence: UInt64 = 0, suggestion: String = "idle", suggestionSequence: Int = 0,
                          startedAt: Date? = nil, notice: ControlNotice? = nil) -> ControlSnapshot {
        ControlSnapshot(version: 2, mode: mode, meetingActive: meeting, dictation: dictation, dictationSequence: dictationSequence,
                        suggestion: suggestion, suggestionSequence: suggestionSequence, inputLevel: 0.25,
                        meetingStartedAt: startedAt, notice: notice)
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
        let started = Date(timeIntervalSince1970: 1_792_600_000)
        let reply = presentation.reply(controls(mode: "ambient", meeting: true, startedAt: started, notice: .meetingExporting), process: 1)
        XCTAssertEqual(Set(reply.keys), ["version", "instance", "status", "phase", "level", "toggleValues", "enabledActions"],
                       "A version 1 host gets only the version 1 keys")
        XCTAssertEqual(reply["version"] as? Int, 1)
    }

    func testVersionTwoRepliesAddTheMeetingStartAndNoticeCode() {
        var presentation = VorssaintPresentation()
        let started = Date(timeIntervalSince1970: 1_792_600_000)
        let meeting = presentation.reply(controls(mode: "ambient", meeting: true, startedAt: started, notice: .meetingExporting),
                                         process: 1, version: 2)
        XCTAssertEqual(meeting["version"] as? Int, 2)
        XCTAssertEqual(meeting["startedAt"] as? String, "2026-10-21T16:26:40Z")
        XCTAssertEqual(meeting["notice"] as? String, "meeting.exporting")
        let quiet = presentation.reply(controls(mode: "ambient"), process: 1, version: 2)
        XCTAssertEqual(Set(quiet.keys), ["version", "instance", "status", "phase", "level", "toggleValues", "enabledActions"])
    }

    func testOnlyVersionTwoRepliesCarryThePreviewAndNeverMoreThanItsLimit() {
        var presentation = VorssaintPresentation()
        let line = "Monroe: ship it on Friday"
        XCTAssertNil(presentation.reply(controls(mode: "ambient"), process: 1, preview: line)["preview"],
                     "A version 1 host never gets text")
        XCTAssertEqual(presentation.reply(controls(mode: "ambient"), process: 1, version: 2, preview: line)["preview"] as? String, line)
        XCTAssertNil(presentation.reply(controls(mode: "ambient"), process: 1, version: 2, preview: "")["preview"])
        let long = presentation.reply(controls(mode: "ambient"), process: 1, version: 2,
                                      preview: String(repeating: "x", count: 500))["preview"] as? String
        XCTAssertEqual(long?.count, TranscriptPreview.maximumLength)
    }
}
