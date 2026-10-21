import XCTest
@testable import JotCore

final class TranscriptPreviewTests: XCTestCase {
    func testShortRowKeepsItsWordsOnOneLineAfterTheSpeaker() {
        XCTAssertEqual(TranscriptPreview.text("Ship it\non  Friday.\t", speaker: "Monroe"), "Monroe: Ship it on Friday.")
        XCTAssertEqual(TranscriptPreview.text("Ship it.", speaker: nil), "Ship it.")
        XCTAssertEqual(TranscriptPreview.text("Ship it.", speaker: "  "), "Ship it.")
    }

    func testEmptyRowHasNoPreview() {
        XCTAssertNil(TranscriptPreview.text(" \n\t", speaker: "Monroe"))
        XCTAssertNil(TranscriptPreview.text("\u{0007}", speaker: nil))
    }

    func testLongRowKeepsItsNewestWordsWithinTheLimitIncludingTheSpeaker() throws {
        let words = (1...100).map { "word\($0)" }.joined(separator: " ")
        let preview = try XCTUnwrap(TranscriptPreview.text(words, speaker: "Monroe"))
        XCTAssertEqual(preview.count, TranscriptPreview.maximumLength)
        XCTAssertTrue(preview.hasPrefix("Monroe: …"))
        XCTAssertTrue(preview.hasSuffix("word100"))
    }

    func testLongSpeakerNameIsCutSoTheWordsKeepRoom() throws {
        let preview = try XCTUnwrap(TranscriptPreview.text(String(repeating: "a ", count: 200), speaker: String(repeating: "N", count: 300)))
        XCTAssertEqual(preview.count, TranscriptPreview.maximumLength)
        XCTAssertTrue(preview.hasPrefix(String(repeating: "N", count: TranscriptPreview.maximumLabelLength) + ": …"))
    }
}
