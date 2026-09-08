import XCTest
@testable import JotCore

final class DictationCleanupTests: XCTestCase {
    func testRemovesStandaloneHesitationsAndTheirCommas() {
        for (input, expected) in [
            ("uh something", "something"),
            ("Uh, send the note.", "send the note."),
            ("I, uh, think we should go.", "I think we should go."),
            ("Send uh the uh, note.", "Send the note."),
            ("The note, uh.", "The note"),
            ("uh, UH... uh", ""),
            ("Uh?", ""),
            ("uh 😀", "😀"),
            ("First paragraph.\n\nUh, next paragraph.", "First paragraph.\n\nnext paragraph.")
        ] { XCTAssertEqual(DictationCleanup.applying(to: input), expected, input) }
    }

    func testLeavesOtherWordsCompoundsAndUnrelatedFormattingAlone() {
        for input in ["huh", "uh-huh", "uh-oh", "Muhammad", "uh_value", "uh2", "éuh", "Send  this.\n\nNext paragraph."] {
            XCTAssertEqual(DictationCleanup.applying(to: input), input)
        }
    }

    func testCleanupFollowsVocabularyWithoutChangingRecognizedSource() throws {
        let recognized = "Uh, swift you eye is ready."
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(VocabularyEntry(preferred: "SwiftUI", heard: "swift you eye"))
        XCTAssertEqual(DictationCleanup.applying(to: vocabulary.applying(to: recognized)), "SwiftUI is ready.")
        XCTAssertEqual(recognized, "Uh, swift you eye is ready.")
    }
}
