import XCTest
@testable import JotCore

final class TranscriptExportTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(_ start: Double, _ end: Double, _ text: String, speaker: String?, mode: String = "ambient", session: String = "s") -> Transcript {
        Transcript(sessionID: session, startedAt: started, startSeconds: start, endSeconds: end, text: text, speakerID: speaker, mode: mode)
    }

    func testUnfinishedSentenceContinuedByUnattributedRowInheritsTheSpeaker() {
        let folded = TranscriptGrouping.foldContinuations([
            row(0, 2, "So the resource owner is", speaker: "speaker-1"),
            row(2.3, 3, "the firm.", speaker: nil),
            row(3.2, 4, "Right.", speaker: "speaker-2")
        ])
        XCTAssertEqual(folded.map(\.speakerID), ["speaker-1", "speaker-1", "speaker-2"])
    }

    func testFoldStopsAtSentenceEndsLongPausesOverlapAndDictation() {
        let folded = TranscriptGrouping.foldContinuations([
            row(0, 2, "That is done.", speaker: "speaker-1"),
            row(2.2, 3, "next thing", speaker: nil),
            row(3, 4, "and then we", speaker: "speaker-1"),
            row(6, 7, "wait too long", speaker: nil),
            row(7, 8, "both talking", speaker: "overlap"),
            row(8.1, 9, "at once", speaker: nil),
            row(9, 10, "typed this", speaker: "speaker-1", mode: "dictation"),
            row(10.1, 11, "not ambient", speaker: nil)
        ])
        XCTAssertEqual(folded.map(\.speakerID), ["speaker-1", nil, "speaker-1", nil, "overlap", nil, "speaker-1", nil])
    }

    func testFoldChainsThroughSeveralFragmentsOfOneSentence() {
        let folded = TranscriptGrouping.foldContinuations([
            row(0, 1, "the client gets", speaker: "speaker-1"),
            row(1.2, 2, "an auth URL and", speaker: nil),
            row(2.1, 3, "sends the user there.", speaker: nil),
            row(3.5, 4, "then what", speaker: nil)
        ])
        XCTAssertEqual(folded.map(\.speakerID), ["speaker-1", "speaker-1", "speaker-1", nil])
    }

    func testSeededSpeakerCarriesAcrossBlockUntilAConfidentChange() {
        // A short uncertain opening keeps the carried speaker; a confident run after a pause still switches.
        let words = [AttributedWord(text: "and then", start: 0, end: 0.6, probabilities: [0.3, 0.3]),
                     AttributedWord(text: "no way", start: 2.0, end: 3.5, probabilities: [0.1, 0.9])]
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init()).map(\.speaker), [nil, "speaker-2"])
        XCTAssertEqual(TranscriptGrouping.turns(words, tuning: .init(), continuing: "speaker-1").map(\.speaker), ["speaker-1", "speaker-2"])
    }

    func testParagraphsMergeSameSpeakerWithinWindowAndMarkdownNamesSpeakers() {
        var labeled = row(0, 1, "Hello there", speaker: "speaker-1"); labeled.speakerLabel = "Innocent"
        var second = row(1.5, 2, "again", speaker: "speaker-1"); second.speakerLabel = "Innocent"
        let rows = [labeled, second, row(12, 13, "later", speaker: "speaker-1"), row(13, 14, "hi", speaker: "speaker-2")]
        let merged = TranscriptExport.paragraphs(rows)
        XCTAssertEqual(merged.map(\.text), ["Hello there again", "later", "hi"])
        let session = TranscriptSession(sessionID: "s", startedAt: started, lastTranscriptAt: started.addingTimeInterval(14), transcriptCount: 4)
        let text = TranscriptExport.markdown(session: session, rows: rows)
        XCTAssertTrue(text.contains("**[0:00:00] Innocent:** Hello there again"), text)
        XCTAssertTrue(text.contains("**[0:00:13] Speaker 2:** hi"), text)
        XCTAssertTrue(text.contains("4 segments, 0:00:14 of audio"), text)
    }

    func testCollidingExportsAndRepeatedExportsPreserveExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TranscriptSession(sessionID: "first", startedAt: started, lastTranscriptAt: started, transcriptCount: 1, title: "Review")
        let second = TranscriptSession(sessionID: "second", startedAt: started, lastTranscriptAt: started, transcriptCount: 1, title: "Review")
        let firstURL = try TranscriptExport.write(session: first, rows: [row(0, 1, "First meeting", speaker: nil)], directory: directory)
        try "User-edited export".write(to: firstURL, atomically: true, encoding: .utf8)
        let secondURL = try TranscriptExport.write(session: second, rows: [row(0, 1, "Second meeting", speaker: nil)], directory: directory)
        let repeatedURL = try TranscriptExport.write(session: second, rows: [row(0, 2, "Updated meeting", speaker: nil)], directory: directory)
        XCTAssertEqual(Set([firstURL, secondURL, repeatedURL]).count, 3)
        XCTAssertEqual(try String(contentsOf: firstURL), "User-edited export")
        XCTAssertTrue(try String(contentsOf: secondURL).contains("Second meeting"))
        XCTAssertTrue(try String(contentsOf: repeatedURL).contains("Updated meeting"))
    }

    func testSessionReadReturnsEveryRowInOrderBeyondOnePage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        for index in 0..<450 { try store.append(row(Double(index), Double(index) + 0.5, "row \(index)", speaker: nil)) }
        try store.append(row(0, 1, "other", speaker: nil, session: "other"))
        let rows = try store.session(id: "s")
        XCTAssertEqual(rows.count, 450)
        XCTAssertEqual(rows.first?.text, "row 0")
        XCTAssertEqual(rows.last?.text, "row 449")
        XCTAssertTrue(try store.session(id: "missing").isEmpty)
    }
}
