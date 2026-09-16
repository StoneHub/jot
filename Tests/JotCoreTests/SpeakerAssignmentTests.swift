import XCTest
@testable import JotCore

final class SpeakerAssignmentTests: XCTestCase {
    func testEachWordTakesTheSegmentAroundItsMidpoint() {
        let segments = [(speaker: "S1", start: 0.0, end: 2.0), (speaker: "S2", start: 2.0, end: 4.0)]
        let words = [(start: 0.1, end: 0.5), (start: 1.8, end: 2.1), (start: 2.5, end: 3.0), (start: 3.9, end: 4.0)]
        XCTAssertEqual(SpeakerAssignment.assign(words: words, segments: segments), ["S1", "S1", "S2", "S2"])
    }

    func testAWordInAGapBetweenSegmentsHasNoSpeaker() {
        let segments = [(speaker: "S1", start: 0.0, end: 1.0), (speaker: "S2", start: 3.0, end: 4.0)]
        let words = [(start: 0.2, end: 0.8), (start: 1.5, end: 2.5), (start: 0.9, end: 1.3), (start: 3.2, end: 3.4)]
        XCTAssertEqual(SpeakerAssignment.assign(words: words, segments: segments), ["S1", nil, nil, "S2"])
        XCTAssertEqual(SpeakerAssignment.assign(words: words, segments: []), [nil, nil, nil, nil])
    }

    func testOverlappingSegmentsGoToTheOneCoveringMoreOfTheWord() {
        let segments = [(speaker: "S1", start: 0.0, end: 2.2), (speaker: "S2", start: 1.8, end: 4.0)]
        // Midpoints all fall inside both segments; S1 covers 0.25 s of the first word against S2's 0.2 s, and loses the other two.
        let words = [(start: 1.85, end: 2.1), (start: 1.7, end: 2.4), (start: 1.85, end: 2.3)]
        XCTAssertEqual(SpeakerAssignment.assign(words: words, segments: segments), ["S1", "S2", "S2"])
    }
}
