import XCTest
@testable import JotCore

final class ControlSnapshotTests: XCTestCase {
    func testControlWireContractHasOnlyPresentationState() throws {
        let snapshot = ControlSnapshot(mode: "dictation", meetingActive: true, dictation: .capturing,
            dictationSequence: 3, suggestion: "ready", suggestionSequence: 2, inputLevel: 0.5)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "mode", "meetingActive", "dictation", "dictationSequence",
            "suggestion", "suggestionSequence", "inputLevel"])
        XCTAssertEqual(try JSONDecoder().decode(ControlSnapshot.self, from: data), snapshot)
    }

    func testLevelIsFiniteAndBoundedWithoutReadingAudio() throws {
        for (input, expected) in [(Double.nan, 0.0), (.infinity, 0), (-1, 0), (3, 1)] {
            let snapshot = ControlSnapshot(mode: "paused", meetingActive: false, dictation: nil,
                dictationSequence: 0, suggestion: "idle", suggestionSequence: 0, inputLevel: input)
            XCTAssertEqual(snapshot.inputLevel, expected)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testMeterFullScaleMapsToFullLevel() {
        XCTAssertEqual(ControlSnapshot.inputLevel(meter: MicrophoneSignal.maxLevel), 1.0)
        XCTAssertEqual(ControlSnapshot.inputLevel(meter: MicrophoneSignal.maxLevel / 2), 0.5)
        XCTAssertEqual(ControlSnapshot.inputLevel(meter: 0), 0)
        let loud = ControlSnapshot(mode: "dictation", meetingActive: false, dictation: .capturing, dictationSequence: 1,
            suggestion: "idle", suggestionSequence: 0, inputLevel: ControlSnapshot.inputLevel(meter: MicrophoneSignal.maxLevel + 3))
        XCTAssertEqual(loud.inputLevel, 1.0, "An out-of-range meter still clamps to full scale")
    }

    func testVersionOneLeavesOutTheVersionTwoFields() throws {
        let snapshot = ControlSnapshot(mode: "ambient", meetingActive: true, dictation: nil, dictationSequence: 0,
            suggestion: "idle", suggestionSequence: 0, inputLevel: 0, meetingStartedAt: Date(), notice: .meetingExporting)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertNil(snapshot.meetingStartedAt)
        XCTAssertNil(snapshot.notice)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "mode", "meetingActive", "dictationSequence",
            "suggestion", "suggestionSequence", "inputLevel"])
    }

    func testVersionTwoCarriesTheMeetingStartAndNoticeCodeAsISO8601() throws {
        let started = Date(timeIntervalSince1970: 1_792_600_000)
        let snapshot = ControlSnapshot(version: 2, mode: "ambient", meetingActive: true, dictation: nil, dictationSequence: 0,
            suggestion: "idle", suggestionSequence: 0, inputLevel: 0, meetingStartedAt: started, notice: .meetingExporting)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601 // as the socket encodes
        let data = try encoder.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["notice"] as? String, "meeting.exporting")
        XCTAssertEqual(object["meetingStartedAt"] as? String, "2026-10-21T16:26:40Z")
        XCTAssertEqual(try ControlSnapshot.decode(data), snapshot)
    }

    func testVersionTwoDropsTheStartWithoutAMeetingAndKeepsUnknownNoticeCodesReadable() throws {
        let idle = ControlSnapshot(version: 2, mode: "paused", meetingActive: false, dictation: nil, dictationSequence: 0,
            suggestion: "idle", suggestionSequence: 0, inputLevel: 0, meetingStartedAt: Date())
        XCTAssertNil(idle.meetingStartedAt)
        XCTAssertNil(idle.notice)
        let later = #"{"version":2,"mode":"paused","meetingActive":false,"dictationSequence":0,"suggestion":"idle","suggestionSequence":0,"inputLevel":0,"notice":"notes.ready"}"#
        XCTAssertEqual(try ControlSnapshot.decode(Data(later.utf8)).notice, "notes.ready")
    }

    func testVersionOnePayloadStillDecodes() throws {
        let v1 = #"{"version":1,"mode":"ambient","meetingActive":true,"dictation":"capturing","dictationSequence":2,"suggestion":"idle","suggestionSequence":0,"inputLevel":0.5}"#
        let snapshot = try ControlSnapshot.decode(Data(v1.utf8))
        XCTAssertEqual(snapshot, ControlSnapshot(mode: "ambient", meetingActive: true, dictation: .capturing, dictationSequence: 2,
            suggestion: "idle", suggestionSequence: 0, inputLevel: 0.5))
        XCTAssertNil(snapshot.meetingStartedAt)
    }

    func testRequestedVersionDefaultsToOneAndRefusesOthers() throws {
        XCTAssertEqual(try ControlSnapshot.requestedVersion([:]), 1)
        XCTAssertEqual(try ControlSnapshot.requestedVersion(["version": 1]), 1)
        XCTAssertEqual(try ControlSnapshot.requestedVersion(["version": 2]), 2)
        for bad in [0, 3, 1.5, "2", true] as [Any] {
            XCTAssertThrowsError(try ControlSnapshot.requestedVersion(["version": bad]), "\(bad)")
        }
    }
}
