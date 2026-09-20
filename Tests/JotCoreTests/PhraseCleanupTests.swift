import XCTest
@testable import JotCore

final class PhraseCleanupTests: XCTestCase {
    func row(_ text: String, _ start: Double, speaker: String? = "speaker-1", session: String = "s") -> Transcript {
        Transcript(sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: start,
            endSeconds: start + 1, text: text, speakerID: speaker, mode: "ambient")
    }
    func testFragmentsBecomeOneSentenceAndKeepOriginalIDs() {
        var buffer = PhraseCleanup()
        let rows = [row("I think uh", 0), row("we could get", 1), row("faster output to the live view.", 2)]
        XCTAssertTrue(buffer.append([rows[0]]).isEmpty)
        XCTAssertTrue(buffer.append([rows[1]]).isEmpty)
        let ready = buffer.append([rows[2]])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready[0].text, "I think uh we could get faster output to the live view.")
        XCTAssertEqual(ready[0].sources.map(\.id), rows.map(\.id))
        XCTAssertEqual(PhraseCleanup.distribute("I think we could get faster output to the live view.", over: rows),
            ["I think", "we could get", "faster output to the live view."])
    }
    func testQuietSpeakerSessionAndSizeBoundaries() {
        for next in [row("next", 4), row("next", 1, speaker: "speaker-2"), row("next", 1, session: "other"), row("next", 13)] {
            var buffer = PhraseCleanup()
            XCTAssertTrue(buffer.append([row("unfinished", 0)]).isEmpty)
            XCTAssertEqual(buffer.append([next]).first?.text, "unfinished")
            XCTAssertEqual(buffer.append([], final: true).first?.text, "next")
            XCTAssertEqual(buffer.pendingCount, 0)
        }
        var buffer = PhraseCleanup()
        let long = row(String(repeating: "word ", count: 390), 0)
        _ = buffer.append([long])
        XCTAssertEqual(buffer.append([row(String(repeating: "more ", count: 20), 1)]).count, 1)
    }
    func testWholePhraseEditCanRemoveFillerRowAndPreserveNumbers() {
        let rows = [row("uh", 0), row("we need 3 boxes", 1), row("not 4", 2)]
        let text = "We need 3 boxes, not 4."
        XCTAssertTrue(CleanupValidation.accepts(text, source: rows.map(\.text).joined(separator: " ")))
        XCTAssertEqual(PhraseCleanup.distribute(text, over: rows), ["", "We need 3 boxes,", "not 4."])
    }
    func testPhraseStorageIsAtomicAndDoesNotResurrectDeletedRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let rows = [row("uh", 0), row("we need boxes", 1)]
        for source in rows { try store.append(source) }
        XCTAssertTrue(try store.setReadablePhrase(["", "We need boxes."], for: rows))
        XCTAssertEqual(try store.session(id: "s").map(\.text), ["", "We need boxes."])
        try store.deleteTranscripts(ids: [rows[1].id])
        XCTAssertFalse(try store.setReadablePhrase(["Should not", "reappear"], for: rows))
        XCTAssertEqual(try store.session(id: "s").map(\.text), [""])
    }
}
