import XCTest
@testable import JotCore

final class SessionFileTests: XCTestCase {
    /// The sample docs/SHARED-CONTRACT.md points Jot for Android at.
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/contract/session-v1.json")
    private let start = Date(timeIntervalSince1970: 1_800_000_000.4)

    private func sample() -> (TranscriptSession, [Transcript]) {
        let session = TranscriptSession(sessionID: "session-a", startedAt: start, lastTranscriptAt: start.addingTimeInterval(12),
                                        transcriptCount: 4, title: "Design review")
        let rows = [
            Transcript(id: "r1", sessionID: "session-a", startedAt: start, startSeconds: 0.5, endSeconds: 2, text: "Let's start with the launch date.",
                       speakerID: "speaker-1", mode: "ambient", speakerLabel: "Ana"),
            Transcript(id: "r2", sessionID: "session-a", startedAt: start, startSeconds: 2.5, endSeconds: 4.25, text: " ", speakerID: "speaker-1", mode: "ambient"),
            // A held dictation keeps its own start with an offset of 0.
            Transcript(id: "r3", sessionID: "session-a", startedAt: start.addingTimeInterval(10), startSeconds: 0, endSeconds: 1.2,
                       text: "Send the notes to the team.", mode: "dictation"),
            Transcript(id: "r4", sessionID: "session-a", startedAt: start, startSeconds: 5, endSeconds: 6, text: "Sounds good.",
                       speakerID: "speaker-2", mode: "ambient", speakerLabel: ""),
        ]
        return (session, rows)
    }

    func testASessionBecomesTheSharedSampleOnTheSessionsClockWithoutIds() throws {
        let (session, rows) = sample()
        let contents = SessionFile.contents(session: session, rows: rows)
        XCTAssertEqual(contents, try SessionFile.decode(Data(contentsOf: fixture)))
        XCTAssertEqual(contents.startedAt, Date(timeIntervalSince1970: 1_800_000_000), "whole seconds")
        let encoded = try SessionFile.encode(contents)
        XCTAssertEqual(try SessionFile.decode(encoded), contents)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("session-a") || text.contains("\"r1\""), "ids stay on this Mac")
    }

    func testRefusesOtherFilesAndNewerVersions() {
        XCTAssertThrowsError(try SessionFile.decode(Data("[]".utf8))) { XCTAssertEqual($0 as? SessionFile.Failure, .notASessionFile) }
        XCTAssertThrowsError(try SessionFile.decode(Data(#"{"format": "jot.vocabulary", "version": 1, "entries": []}"#.utf8))) {
            XCTAssertEqual($0 as? SessionFile.Failure, .notASessionFile)
        }
        XCTAssertThrowsError(try SessionFile.decode(Data(#"{"format": "jot.session", "version": 2, "startedAt": "2027-01-15T08:00:00Z", "rows": []}"#.utf8))) {
            XCTAssertEqual($0 as? SessionFile.Failure, .newerVersion(2))
        }
        XCTAssertThrowsError(try SessionFile.decode(Data(#"{"format": "jot.session", "version": 1, "startedAt": "2027-01-15T08:00:00Z", "rows": [{"start": 0}]}"#.utf8))) {
            XCTAssertEqual($0 as? SessionFile.Failure, .unreadableRows)
        }
    }
}
