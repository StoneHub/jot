import XCTest
import SQLite3
@testable import JotCore

final class HistoryDeletionTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, session: String = "a", start: Double = 0, text: String = "hello", mode: String = "ambient") -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: start, endSeconds: start + 1, text: text, speakerID: mode == "ambient" ? "speaker-1" : nil, mode: mode)
    }

    func testClearRemovesEveryDictationAndKeepsSessions() throws {
        do {
            let store = try TranscriptStore(directory: directory)
            for index in 0..<450 { try store.append(row("\(index)", session: "d\(index)", start: Double(index), mode: "dictation")) }
            try store.appendEvent(CaptureEvent(sessionID: "d1", kind: "processing_error", detail: "failed"))
            try store.append(row("kept-ambient"))
            try store.setTitle(sessionID: "a", title: "Old meeting")
            try store.label(sessionID: "a", speakerID: "speaker-1", name: "Old speaker")
            try store.appendEvent(CaptureEvent(sessionID: "a", kind: "started", detail: "Started"))
            try store.clearHistory()
            XCTAssertEqual(try store.metrics().transcriptCount, 1)
            XCTAssertEqual(try store.events().map(\.sessionID), ["a"])
        }
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.sessions().first?.title, "Old meeting")
        XCTAssertEqual(try store.read(id: "kept-ambient")?.speakerLabel, "Old speaker")
        XCTAssertTrue(try store.search("hello").allSatisfy { $0.mode == "ambient" })
        XCTAssertNil(try store.read(id: "7"))
    }

    func testRecentAndSearchCanReadOneKindOfRow() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("amb")); try store.append(row("dict", session: "d", start: 5, mode: "dictation"))
        XCTAssertEqual(try store.recent(mode: "dictation").map(\.id), ["dict"])
        XCTAssertEqual(try store.recent(mode: "ambient").map(\.id), ["amb"])
        XCTAssertEqual(try store.recent().count, 2)
        XCTAssertEqual(try store.search("hello", mode: "dictation").map(\.id), ["dict"])
        XCTAssertEqual(try store.search("hello").count, 2)
    }

    func testSessionDeletionKeepsOtherSessionsAndRemovesRelatedMetadata() throws {
        let store = try TranscriptStore(directory: directory)
        for session in ["a", "b"] {
            try store.append(row(session, session: session))
            try store.setTitle(sessionID: session, title: session)
            try store.label(sessionID: session, speakerID: "speaker-1", name: session)
            try store.appendEvent(CaptureEvent(sessionID: session, kind: "started", detail: "Started"))
        }
        try store.deleteSession(id: "a")
        XCTAssertNil(try store.read(id: "a"))
        XCTAssertEqual(try store.read(id: "b")?.speakerLabel, "b")
        XCTAssertEqual(try store.events().map(\.sessionID), ["b"])
        try store.append(row("a-new"))
        XCTAssertNil(try store.read(id: "a-new")?.speakerLabel)
        XCTAssertNil(try store.sessions().first { $0.sessionID == "a" }?.title)
    }

    func testDeletingGroupedCardDeletesExactlyItsSourceRows() throws {
        let store = try TranscriptStore(directory: directory)
        let source = [row("one"), row("two", start: 1.2), row("hidden", start: 2.3, text: "uh"), row("other", session: "b", start: 20)]
        for item in source { try store.append(item) }
        let groups = TranscriptGrouping.historyGroups(source, tuning: .init())
        let grouped = try XCTUnwrap(groups.first { $0.sourceIDs.count == 2 })
        XCTAssertEqual(Set(grouped.sourceIDs), ["one", "two"])
        try store.deleteTranscripts(ids: grouped.sourceIDs)
        XCTAssertNil(try store.read(id: "one"))
        XCTAssertNil(try store.read(id: "two"))
        XCTAssertNotNil(try store.read(id: "hidden"))
        XCTAssertNotNil(try store.read(id: "other"))
    }

    func testFailedDeletionRollsBackAllTables() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("kept")); try store.append(row("gone", session: "d", mode: "dictation"))
        try store.setTitle(sessionID: "a", title: "Keep with transcript")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_transcript_delete BEFORE DELETE ON transcripts BEGIN SELECT RAISE(ABORT, 'test failure'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.clearHistory())
        XCTAssertNotNil(try store.read(id: "kept")); XCTAssertNotNil(try store.read(id: "gone"))
        XCTAssertEqual(try store.sessions().first?.title, "Keep with transcript")
    }

    func testLastRowDeletionCleansMetadataButPartialDeletionKeepsIt() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("one")); try store.append(row("two", start: 10))
        try store.setTitle(sessionID: "a", title: "Meeting")
        try store.label(sessionID: "a", speakerID: "speaker-1", name: "Person")
        try store.appendEvent(CaptureEvent(sessionID: "a", kind: "started", detail: "Started"))
        try store.deleteTranscripts(ids: ["one", "missing"])
        XCTAssertEqual(try store.sessions().first?.title, "Meeting")
        XCTAssertEqual(try store.read(id: "two")?.speakerLabel, "Person")
        try store.deleteTranscripts(ids: ["two"])
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertTrue(try store.events().isEmpty)
        try store.append(row("new"))
        XCTAssertNil(try store.read(id: "new")?.speakerLabel)
        XCTAssertNil(try store.sessions().first?.title)
    }
}
