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

    /// A word of one row, by row id.
    private func spoken(in row: String, _ start: Double, _ end: Double) -> StoredWord {
        StoredWord(transcriptID: row, position: 0, word: "w", startSeconds: start, endSeconds: end, probabilities: [])
    }

    func testNamesGivenToLiveSpeakersFollowTheirVoicesOntoThePassSpeakers() {
        // Live numbered the two voices the other way round from the pass.
        let words = [spoken(in: "a", 0, 0.5), spoken(in: "a", 0.5, 1), spoken(in: "b", 2, 2.5), spoken(in: "b", 2.5, 3)]
        let before = ["a": "speaker-2", "b": "speaker-1"]
        let labels = ["speaker-2": "Ada", "speaker-1": "Grace"]
        let carried = SpeakerPassRelabel.carriedLabels(labels, words: words, before: before, after: ["speaker-1", "speaker-1", "speaker-2", "speaker-2"])
        XCTAssertEqual(carried, ["speaker-1": "Ada", "speaker-2": "Grace"])
    }

    func testTwoLiveNamesForOnePassVoiceKeepTheOneThatSpokeLonger() {
        // Live split one voice in two; the pass heard one. A live speaker with no name moves nothing.
        let words = [spoken(in: "a", 0, 2), spoken(in: "b", 3, 3.5), spoken(in: "c", 4, 5)]
        let before = ["a": "speaker-1", "b": "speaker-2", "c": "speaker-3"]
        let labels = ["speaker-1": "Ada", "speaker-2": "Ada's echo"]
        let carried = SpeakerPassRelabel.carriedLabels(labels, words: words, before: before, after: ["speaker-1", "speaker-1", "speaker-2"])
        XCTAssertEqual(carried, ["speaker-1": "Ada"])
    }

    func testANameDoesNotMoveOntoAVoiceItGaveOnlyABorrowedWord() {
        // Live split Ada in two and both halves were named Ada. Grace was never named. The pass hands one of Ada's words to Grace's voice, which must not become "Ada".
        let words = [spoken(in: "a", 0, 10), spoken(in: "b", 11, 15), spoken(in: "b", 15, 15.3), spoken(in: "c", 16, 21)]
        let before = ["a": "speaker-1", "b": "speaker-2", "c": "speaker-3"]
        let labels = ["speaker-1": "Ada", "speaker-2": "Ada"]
        let carried = SpeakerPassRelabel.carriedLabels(labels, words: words, before: before, after: ["speaker-1", "speaker-1", "speaker-2", "speaker-2"])
        XCTAssertEqual(carried, ["speaker-1": "Ada"])
    }

    func testLiveSpeakersGivenTheSameNameCountAsOne() {
        // Each half of Ada gave less time than Grace, but together they gave more. Names compare trimmed and without case.
        let words = [spoken(in: "a", 0, 1), spoken(in: "b", 2, 3), spoken(in: "c", 4, 5.5)]
        let before = ["a": "speaker-1", "b": "speaker-2", "c": "speaker-3"]
        let labels = ["speaker-1": "Ada", "speaker-2": "ada ", "speaker-3": "Grace"]
        XCTAssertEqual(SpeakerPassRelabel.carriedLabels(labels, words: words, before: before, after: ["speaker-1", "speaker-1", "speaker-1"]), ["speaker-1": "Ada"])
    }

    func testUnattributedRowsKeepANameOffTheVoiceTheyMostlyFill() {
        let words = [spoken(in: "a", 0, 1), spoken(in: "x", 2, 4)]
        XCTAssertEqual(SpeakerPassRelabel.carriedLabels(["speaker-1": "Ada"], words: words, before: ["a": "speaker-1"], after: ["speaker-1", "speaker-1"]), [:])
    }

    func testANameWhoseWordsThePassGaveNoOneIsDropped() {
        let words = [spoken(in: "a", 0, 1), spoken(in: "b", 2, 3)]
        let carried = SpeakerPassRelabel.carriedLabels(["speaker-1": "Ada", "speaker-2": "Grace"], words: words,
                                                       before: ["a": "speaker-1", "b": "speaker-2"], after: ["speaker-1", nil])
        XCTAssertEqual(carried, ["speaker-1": "Ada"])
    }
}
