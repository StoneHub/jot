import XCTest
@testable import JotCore
final class TranscriptGroupingTests: XCTestCase {
    func testHesitationDoesNotCreateSpeakerOrStatement() {
        let words = [AttributedWord(text:"I think",start:0,end:1,probabilities:[0.9,0.1]),
                     AttributedWord(text:"um",start:1,end:1.2,probabilities:[0.1,0.9]),
                     AttributedWord(text:"we should go",start:1.2,end:2.5,probabilities:[0.9,0.1])]
        let turns = TranscriptGrouping.turns(words,tuning:.init())
        XCTAssertEqual(turns.count,1); XCTAssertEqual(turns[0].speaker,"speaker-1")
        XCTAssertEqual(turns[0].text,"I think um we should go")
    }
    func testSustainedSpeakerChangeStillSplits() {
        let words = [AttributedWord(text:"First person",start:0,end:1,probabilities:[0.9,0.1]),
                     AttributedWord(text:"Second person",start:1,end:2.5,probabilities:[0.1,0.9])]
        XCTAssertEqual(TranscriptGrouping.turns(words,tuning:.init()).map(\.speaker),["speaker-1","speaker-2"])
    }
    func testPauseAndConfidenceCanBeTuned() {
        let words = [AttributedWord(text:"One",start:0,end:1,probabilities:[0.6]),
                     AttributedWord(text:"Two",start:2.2,end:3.2,probabilities:[0.6])]
        XCTAssertEqual(TranscriptGrouping.turns(words,tuning:.init()).count,2)
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
