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
}
