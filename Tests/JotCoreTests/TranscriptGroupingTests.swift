import XCTest
@testable import JotCore
final class TranscriptGroupingTests: XCTestCase {
    func testRegroupKeepsOrdinarySymbolWords() {
        let words = ["for", "a", "period", "of", "time", "and", "colon", "cancer"]
            .enumerated().map { StoredWord(transcriptID: "t", position: $0.offset, word: $0.element,
                startSeconds: Double($0.offset), endSeconds: Double($0.offset) + 0.5, probabilities: [0.9]) }
        let turns = TranscriptGrouping.regroup(words: words, tuning: .init())
        XCTAssertEqual(turns.map(\.text), ["for a period of time and colon cancer"])
    }

    func testBriefUncertaintyKeepsSpeakerButLongUncertaintyDoesNot() {
        let words = [AttributedWord(text: "We discussed", start: 0, end: 1.5, probabilities: [0.9]),
                     AttributedWord(text: "the next step", start: 1.5, end: 3, probabilities: []),
                     AttributedWord(text: "today", start: 3, end: 4.5, probabilities: [0.9]),
                     AttributedWord(text: "uncertain speech", start: 4.5, end: 7, probabilities: [])]
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init()).map(\.speaker), ["speaker-1", nil])
    }

    func testHistoryJoinsUnfinishedSentenceAndPreservesSourceIDs() {
        let first = Transcript(sessionID: "s", startedAt: .distantPast, startSeconds: 0, endSeconds: 2, text: "You know what I", speakerID: "speaker-1", mode: "ambient")
        let next = Transcript(sessionID: "s", startedAt: .distantPast, startSeconds: 1.95, endSeconds: 3, text: "mean?", mode: "ambient")
        let groups = TranscriptGrouping.historyGroups([next, first], tuning: .init())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].transcript.text, "You know what I mean?")
        XCTAssertEqual(groups[0].sourceIDs, [first.id, next.id])
        XCTAssertNil(next.speakerID)
        var other = next; other.sessionID = "other"
        XCTAssertEqual(TranscriptGrouping.historyGroups([first, other], tuning: .init()).count, 2)
    }
    func testHesitationDoesNotCreateSpeakerOrStatement() {
        let words = [AttributedWord(text:"I think",start:0,end:1,probabilities:[0.9,0.1]),
                     AttributedWord(text:"um",start:1,end:1.2,probabilities:[0.1,0.9]),
                     AttributedWord(text:"we should go",start:1.2,end:2.5,probabilities:[0.9,0.1])]
        var tuning = TranscriptionTuning(); tuning.minimumSpeakerTurn = 0.8
        let turns = TranscriptGrouping.turns(words,tuning:tuning)
        XCTAssertEqual(turns.count,1); XCTAssertEqual(turns[0].speaker,"speaker-1")
        XCTAssertEqual(turns[0].text,"I think um we should go")
    }
    func testConfidentShortReplyGetsItsOwnSpeaker() {
        let words = [AttributedWord(text:"we'll get it checked first thing in the morning then.",start:0,end:3,probabilities:[0.9,0.05]),
                     AttributedWord(text:"Good man.",start:3.1,end:3.6,probabilities:[0.05,0.95]),
                     AttributedWord(text:"Alright,",start:3.7,end:4.2,probabilities:[0.9,0.05]),
                     AttributedWord(text:"Yeah.",start:4.3,end:4.6,probabilities:[0.3,0.7])]
        // 0.95 for speaker 2 confirms the half-second reply; 0.7 is not clear enough and stays with the current speaker.
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init()).map(\.speaker), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init()).map(\.text).last, "Alright, Yeah.")
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init()).map(\.wordRange), [0..<1, 1..<2, 2..<4])
    }
    func testSustainedSpeakerChangeStillSplits() {
        let words = [AttributedWord(text:"First person",start:0,end:1,probabilities:[0.9,0.1]),
                     AttributedWord(text:"Second person",start:1,end:2.5,probabilities:[0.1,0.9])]
        var tuning = TranscriptionTuning(); tuning.minimumSpeakerTurn = 0.8
        XCTAssertEqual(TranscriptGrouping.turns(words,tuning:tuning).map(\.speaker),["speaker-1","speaker-2"])
    }
    func testPauseAndConfidenceCanBeTuned() {
        let words = [AttributedWord(text:"One",start:0,end:1,probabilities:[0.6]),
                     AttributedWord(text:"Two",start:2.2,end:3.2,probabilities:[0.6])]
        var old = TranscriptionTuning(); old.paragraphPause = 1
        XCTAssertEqual(TranscriptGrouping.turns(words,tuning:old).count,2)
        XCTAssertNil(TranscriptGrouping.turns(words,tuning:.init())[0].speaker)
        var tuning = TranscriptionTuning(); tuning.speakerConfidence = 0.5; tuning.paragraphPause = 1.5
        let turns = TranscriptGrouping.turns(words,tuning:tuning)
        XCTAssertEqual(turns.count,1); XCTAssertEqual(turns[0].speaker,"speaker-1")
    }
    func testHistoryFilteringDoesNotRemoveSourceWords() {
        let rows = [Transcript(sessionID:"s",startedAt:Date(timeIntervalSince1970:0),startSeconds:0,endSeconds:1,text:"Hello",speakerID:"speaker-1",mode:"ambient"),
                    Transcript(sessionID:"s",startedAt:Date(timeIntervalSince1970:0),startSeconds:1.1,endSeconds:1.3,text:"Um…",speakerID:"speaker-2",mode:"ambient"),
                    Transcript(sessionID:"s",startedAt:Date(timeIntervalSince1970:0),startSeconds:1.4,endSeconds:2,text:"again",speakerID:"speaker-1",mode:"ambient")]
        let presented = TranscriptGrouping.history(rows,tuning:.init())
        XCTAssertEqual(presented.count,1); XCTAssertEqual(presented[0].text,"Hello again")
        XCTAssertEqual(rows.count,3); XCTAssertEqual(rows[1].text,"Um…")
        var tuning = TranscriptionTuning(); tuning.hideFillerRows = false
        XCTAssertEqual(TranscriptGrouping.history(rows,tuning:tuning).count,3)
        XCTAssertFalse(TranscriptGrouping.isFillerOnly("um, I disagree"))
    }
}
