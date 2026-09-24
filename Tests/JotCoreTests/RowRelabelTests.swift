import XCTest
@testable import JotCore

final class RowRelabelTests: XCTestCase {
    /// One row's words, half a second apart, each a quarter second long.
    private func words(_ row: String, _ text: String, from start: Double) -> [StoredWord] {
        text.split(separator: " ").enumerated().map { index, word in
            StoredWord(transcriptID: row, position: index, word: String(word), startSeconds: start + Double(index) * 0.5, endSeconds: start + Double(index) * 0.5 + 0.25, probabilities: [])
        }
    }

    func testRowsWhoseWordsShareOneSpeakerAreOnlyRelabeled() throws {
        let stored = words("a", "hello there", from: 0) + words("b", "general question", from: 2) + words("c", "um", from: 4)
        let plan = try RowRelabel(words: stored, speakers: ["speaker-1", "speaker-1", "speaker-2", "speaker-2", nil], readable: ["a": "Hello there."])
        XCTAssertEqual(plan.kept.map(\.rowID), ["a", "b", "c"])
        XCTAssertEqual(plan.kept.map(\.speaker), ["speaker-1", "speaker-2", nil])
        XCTAssertTrue(plan.splits.isEmpty)
    }

    func testARowSplitsAtEachSpeakerChangeInsideIt() throws {
        let plan = try RowRelabel(words: words("a", "one two three four", from: 10), speakers: ["A", "A", "B", "A"], readable: [:])
        XCTAssertTrue(plan.kept.isEmpty)
        XCTAssertEqual(plan.splits.map(\.rowID), ["a"])
        let pieces = try XCTUnwrap(plan.splits.first).pieces
        XCTAssertEqual(pieces.map(\.text), ["one two", "three", "four"])
        XCTAssertEqual(pieces.map(\.speaker), ["A", "B", "A"])
        XCTAssertEqual(pieces.map(\.start), [10, 11, 11.5])
        XCTAssertEqual(pieces.map(\.end), [10.75, 11.25, 11.75])
        XCTAssertEqual(pieces.map { $0.words.map(\.word) }, [["one", "two"], ["three"], ["four"]])
        XCTAssertEqual(pieces.map { $0.words.map(\.position) }, [[0, 1], [0], [0]])
    }

    func testEachPieceTakesItsShareOfTheCleanedText() throws {
        let stored = words("a", "so um I think we should okay", from: 0)
        let speakers: [String?] = ["A", "A", "A", "A", "A", "A", "B"]
        let plan = try RowRelabel(words: stored, speakers: speakers, readable: ["a": "So I think we should, okay."])
        XCTAssertEqual(plan.splits.first?.pieces.map(\.text), ["so um I think we should", "okay"])
        XCTAssertEqual(plan.splits.first?.pieces.map(\.readable), ["So I think we should,", "okay."])
    }

    func testSpokenSymbolNamesStayWordsInKeptAndSplitRows() throws {
        let stored = words("a", "email me at sign home period", from: 0) + words("b", "the grace period ended", from: 4)
        let speakers: [String?] = ["A", "A", "A", "A", "B", "B", "A", "A", "A", "A"]
        let plan = try RowRelabel(words: stored, speakers: speakers, readable: [:])
        XCTAssertEqual(plan.kept.map(\.rowID), ["b"], "A kept row only takes a speaker, so its stored words stay as spoken")
        XCTAssertEqual(plan.splits.first?.pieces.map(\.text), ["email me at sign", "home period"], "Pieces are the row's words as spoken, like every stored row")
    }

    func testPiecesOfARowThatWasNeverCleanedHaveNoCleanedText() throws {
        let plan = try RowRelabel(words: words("a", "one two", from: 0), speakers: ["A", "B"], readable: ["other": "Other."])
        XCTAssertEqual(plan.splits.first?.pieces.map(\.readable), [nil, nil])
    }

    func testOneSpeakerPerWordIsRequired() {
        XCTAssertThrowsError(try RowRelabel(words: words("a", "one two", from: 0), speakers: ["A"], readable: [:]))
    }
}
