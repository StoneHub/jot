import XCTest
@testable import JotCore
@testable import JotEngine

final class LabDiarizationTests: XCTestCase {
    private func row(_ start: Double, _ end: Double, _ speaker: String?) -> LabRow {
        LabRow(start: start, end: end, liveSpeaker: speaker, passSpeaker: nil, rawText: "w", cleanedText: nil, cleanup: .noCleanedText)
    }

    /// Captions are the reference and rows the hypothesis; ids are matched to voices, and 0.25 s each side of every cue
    /// boundary is left out.
    func testDiarizationErrorScoresStoredRowsAgainstCaptionSpeakers() throws {
        let captions = [LabCaptions.Cue(start: 0, end: 10, text: "a", speaker: "Kim"), LabCaptions.Cue(start: 10, end: 20, text: "b", speaker: "Lee")]
        let right = try XCTUnwrap(LabDiarization.error(captions: captions, rows: [row(0, 10, "speaker-2"), row(10, 20, "speaker-1")], speaker: \.liveSpeaker))
        XCTAssertEqual(right.speechSeconds, 19, accuracy: 0.02, "Each cue loses 0.25 s at both ends")
        XCTAssertEqual(right.rate, 0, accuracy: 0.001, "Speaker ids are arbitrary")

        let late = try XCTUnwrap(LabDiarization.error(captions: captions,
            rows: [row(0, 15, "speaker-1"), row(15, 20, "speaker-2")], speaker: \.liveSpeaker))
        XCTAssertEqual(late.confusionSeconds, 4.75, accuracy: 0.02, "speaker-1 kept talking into Lee's turn")
        XCTAssertEqual(late.missedSeconds + late.falseAlarmSeconds, 0, accuracy: 0.001)

        let unlabeled = try XCTUnwrap(LabDiarization.error(captions: captions, rows: [row(0, 10, nil), row(10, 20, "overlap"), row(20, 22, "speaker-1")],
            speaker: \.liveSpeaker))
        XCTAssertEqual(unlabeled.missedSeconds, 19, accuracy: 0.02, "Rows with no one speaker are missed speech")
        XCTAssertEqual(unlabeled.falseAlarmSeconds, 1.75, accuracy: 0.02, "Row time after the last cue is false alarm")

        let untagged = [captions[0], LabCaptions.Cue(start: 10, end: 20, text: "b", speaker: nil)]
        XCTAssertNil(LabDiarization.error(captions: untagged, rows: [row(0, 20, "speaker-1")], speaker: \.liveSpeaker))
    }
}
