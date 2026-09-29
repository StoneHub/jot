import XCTest
@testable import JotCore

final class DictationCleanupTests: XCTestCase {
    func testSingleWordInsertionDoesNotBecomeProse() {
        for (source, expected) in [("purple.", "purple"), ("purple", "purple"), ("I.", "I"), ("a.", "a"), ("  café.\n", "café"),
                                   ("don't.", "don't"), ("blue-green.", "blue-green"), ("Uh, purple.", "purple")] {
            let prepared = DictationCleanup.prepare(source)
            XCTAssertEqual(prepared.text, expected, source)
            XCTAssertFalse(prepared.needsProseCleanup, source)
        }
    }

    func testPunctuationIsNormalizedBeforeSymbolsAndVocabulary() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(VocabularyEntry(preferred: "Word.", heard: "word"))
        XCTAssertEqual(DictationCleanup.prepare("word.", vocabulary: vocabulary).text, "Word.")
        for source in ["purple period.", "purple dot."] {
            let prepared = DictationCleanup.prepare(source)
            XCTAssertEqual(prepared.text, "purple.", source)
            XCTAssertFalse(prepared.needsProseCleanup, "Explicit punctuation must not be rewritten")
        }
        XCTAssertEqual(DictationCleanup.prepare("period.").text, ".")
    }

    func testDoesNotStripSentenceOrMeaningfulPunctuation() {
        for source in ["I want the blue one.", "Go now.", "the blue one.", "Dr.", "J.", "U.S.", "3.14", "v1.2.3",
                       "example.com", "file.swift", "purple...", "Really?", "Stop!"] {
            XCTAssertEqual(DictationCleanup.prepare(source).text, source, source)
        }
        XCTAssertTrue(DictationCleanup.prepare("Go now.").needsProseCleanup, "Short complete sentences still get prose cleanup")
        XCTAssertTrue(DictationCleanup.prepare("the blue one.").needsProseCleanup, "The model decides whether a phrase is complete")
    }

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
