import XCTest
@testable import JotCore

final class SessionTitleTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_757_331_660)

    func testTitleShowsInSessionsListAndAnEmptyTitleRemovesIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        try store.append(Transcript(sessionID: "s1", startedAt: started, startSeconds: 0, endSeconds: 1, text: "hi", mode: "ambient"))
        try store.append(Transcript(sessionID: "s2", startedAt: started.addingTimeInterval(100), startSeconds: 0, endSeconds: 1, text: "yo", mode: "ambient"))
        XCTAssertNil(try store.sessions().first?.title)

        try store.setTitle(sessionID: "s1", title: "  Webex review  ")
        let named = try store.sessions().first { $0.sessionID == "s1" }
        XCTAssertEqual(named?.title, "Webex review")
        XCTAssertNil(try store.sessions().first { $0.sessionID == "s2" }?.title)

        try store.setTitle(sessionID: "s1", title: "Renamed")
        XCTAssertEqual(try store.sessions().first { $0.sessionID == "s1" }?.title, "Renamed")
        try store.setTitle(sessionID: "s1", title: "   ")
        XCTAssertNil(try store.sessions().first { $0.sessionID == "s1" }?.title)
    }

    func testDictationRowsStayOutOfTheSessionsList() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        try store.append(Transcript(sessionID: "meeting", startedAt: started, startSeconds: 0, endSeconds: 5, text: "hello", mode: "ambient"))
        for index in 0..<3 {
            try store.append(Transcript(sessionID: "fn-\(index)", startedAt: started.addingTimeInterval(Double(index) + 10), startSeconds: 0, endSeconds: 1, text: "typed", mode: "dictation"))
        }
        XCTAssertEqual(try store.sessions().map(\.sessionID), ["meeting"])
        XCTAssertEqual(try store.recent().count, 4, "History still shows every dictation")
    }

    func testExportFileNameUsesDateAndTitleAndStripsPathCharacters() {
        let untitled = TranscriptSession(sessionID: "s", startedAt: started, lastTranscriptAt: started, transcriptCount: 1)
        XCTAssertTrue(TranscriptExport.fileName(for: untitled).hasSuffix(" Session.md"), TranscriptExport.fileName(for: untitled))
        let titled = TranscriptSession(sessionID: "s", startedAt: started, lastTranscriptAt: started, transcriptCount: 1, title: "Q3: plan / review?")
        let name = TranscriptExport.fileName(for: titled)
        XCTAssertTrue(name.hasSuffix(" Q3 plan review.md"), name)
        XCTAssertFalse(name.contains("/"))
        let session = TranscriptSession(sessionID: "s", startedAt: started, lastTranscriptAt: started, transcriptCount: 1, title: "Standup")
        XCTAssertTrue(TranscriptExport.markdown(session: session, rows: [Transcript(sessionID: "s", startedAt: started, startSeconds: 0, endSeconds: 1, text: "hi", mode: "ambient")]).hasPrefix("# Standup "))
    }
}
