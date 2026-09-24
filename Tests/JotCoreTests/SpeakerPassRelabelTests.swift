import XCTest
@testable import JotCore

final class SpeakerPassRelabelTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> StoredWord {
        StoredWord(transcriptID: "t", position: 0, word: text, startSeconds: start, endSeconds: end, probabilities: [0.9, 0.05])
    }

    func testPassIDsAreNumberedByFirstSpeechNotByName() {
        let segments: [SpeakerPassRelabel.Segment] = [("S3", 4, 6), ("S1", 0, 2), ("S3", 2, 4), ("S2", 6, 8)]
        XCTAssertEqual(SpeakerPassRelabel.speakerIDs(segments: segments), ["S1": "speaker-1", "S3": "speaker-2", "S2": "speaker-3"])
        let result = SpeakerPassRelabel.renumbered(SpeakerPassResult(segments: segments, speakers: ["S1": [1], "S2": [2], "S3": [3]], durationSeconds: 8, processingSeconds: 1))
        XCTAssertEqual(result.segments.map(\.speaker), ["speaker-2", "speaker-1", "speaker-2", "speaker-3"])
        XCTAssertEqual(result.speakers, ["speaker-1": [1], "speaker-3": [2], "speaker-2": [3]])
        // Renumbering what was already renumbered changes nothing, so a Regroup from stored segments keeps the labels.
        XCTAssertEqual(SpeakerPassRelabel.speakerIDs(segments: result.segments), ["speaker-1": "speaker-1", "speaker-2": "speaker-2", "speaker-3": "speaker-3"])
    }

    func testEachWordTakesThePassSpeakerAroundItsMidpoint() {
        // "there" starts in S1's segment, but its midpoint falls in S2's.
        let words = [word("Hello", 0, 0.4), word("there", 0.5, 1.1), word("Hi", 1.2, 1.5)]
        let segments: [SpeakerPassRelabel.Segment] = [("S1", 0, 0.7), ("S2", 0.7, 2)]
        XCTAssertEqual(SpeakerPassRelabel.speakers(words: words, segments: segments, tuning: .init()), ["speaker-1", "speaker-2", "speaker-2"])
    }

    func testAnUncoveredWordKeepsThePreviousSpeakerAcrossARowWithinThePauseOnly() {
        let words = [StoredWord(transcriptID: "t1", position: 0, word: "One", startSeconds: 0, endSeconds: 0.5, probabilities: []),
                     StoredWord(transcriptID: "t2", position: 0, word: "two", startSeconds: 0.6, endSeconds: 1.0, probabilities: []),
                     StoredWord(transcriptID: "t3", position: 0, word: "three", startSeconds: 3.0, endSeconds: 3.4, probabilities: [])]
        var tuning = TranscriptionTuning()
        tuning.paragraphPause = 1.5
        XCTAssertEqual(SpeakerPassRelabel.speakers(words: words, segments: [("S1", 0, 0.55)], tuning: tuning), ["speaker-1", "speaker-1", nil])
    }

    func testWithoutSegmentsNoWordHasASpeaker() {
        let words = [word("One", 0, 0.5), word("two", 0.6, 1.0)]
        XCTAssertEqual(SpeakerPassRelabel.speakers(words: words, segments: [], tuning: .init()), [nil, nil])
    }

    func testWordsSplitIntoTurnsWhereThePassChangesSpeakerIgnoringLiveProbabilities() {
        let words = [word("Hello", 0, 0.4), word("there", 0.5, 0.9), word("Hi", 1.0, 1.3), word("back", 1.35, 1.7), word("So", 1.8, 2.0)]
        let segments: [SpeakerPassRelabel.Segment] = [("S1", 0, 0.95), ("S2", 0.95, 1.75), ("S1", 1.75, 2.1)]
        let turns = SpeakerPassRelabel.turns(words: words, segments: segments, tuning: .init())
        XCTAssertEqual(turns.map(\.speaker), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(turns.map(\.text), ["Hello there", "Hi back", "So"])
        XCTAssertEqual(turns.map(\.wordRange), [0..<2, 2..<4, 4..<5])
        XCTAssertEqual(turns.map(\.start), [0, 1.0, 1.8]); XCTAssertEqual(turns.map(\.end), [0.9, 1.7, 2.0])
    }

    func testAnUncoveredWordKeepsThePreviousSpeakerWithinThePauseAndIsUnattributedAfterIt() {
        let words = [word("One", 0, 0.5), word("two", 0.6, 1.0), word("three", 3.0, 3.4), word("four", 3.5, 3.9)]
        let segments: [SpeakerPassRelabel.Segment] = [("S1", 0, 0.55)]
        var tuning = TranscriptionTuning(); tuning.paragraphPause = 1.5
        let turns = SpeakerPassRelabel.turns(words: words, segments: segments, tuning: tuning)
        XCTAssertEqual(turns.map(\.speaker), ["speaker-1", nil])
        XCTAssertEqual(turns.map(\.text), ["One two", "three four"])
        XCTAssertEqual(SpeakerPassRelabel.turns(words: words, segments: [], tuning: tuning).map(\.speaker), [nil, nil])
    }

    func testAParagraphPauseBreaksARowEvenForTheSameSpeaker() {
        let words = [word("First", 0, 0.5), word("second", 2.5, 3.0), word("at", 3.1, 3.5), word("sign", 3.6, 3.9), word("home", 4.0, 4.3)]
        let turns = SpeakerPassRelabel.turns(words: words, segments: [("S1", 0, 4)], tuning: .init())
        XCTAssertEqual(turns.map(\.speaker), ["speaker-1", "speaker-1"])
        XCTAssertEqual(turns.map(\.text), ["First", "second at sign home"])
    }

    func testSpeakerPassKeepsOrdinarySymbolWords() {
        let words = ["for", "a", "period", "of", "time", "and", "colon", "cancer"]
            .enumerated().map { word($0.element, Double($0.offset), Double($0.offset) + 0.5) }
        let turns = SpeakerPassRelabel.turns(words: words, segments: [("S1", 0, 8)], tuning: .init())
        XCTAssertEqual(turns.map(\.text), ["for a period of time and colon cancer"])
    }
}
