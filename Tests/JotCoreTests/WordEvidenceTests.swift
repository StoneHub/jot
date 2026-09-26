import XCTest
import SQLite3
@testable import JotCore

final class WordEvidenceTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, session: String = "a", start: Double = 0, end: Double = 2, text: String = "hello there", speaker: String? = "speaker-1") -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: start, endSeconds: end, text: text, speakerID: speaker, mode: "ambient")
    }
    private func word(_ transcript: String, _ position: Int, _ text: String, _ start: Double, _ end: Double, _ probabilities: [Float] = [0.7, 0.1, 0.1, 0.1]) -> StoredWord {
        StoredWord(transcriptID: transcript, position: position, word: text, startSeconds: start, endSeconds: end, probabilities: probabilities)
    }
    private func count(_ sql: String) throws -> Int {
        var db: OpaquePointer?; var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        guard sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database("query failed") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func testWordsRoundTripInTimeOrderAndSurviveReopening() throws {
        do {
            let store = try TranscriptStore(directory: directory)
            try store.append(row("t1", start: 0, end: 2)); try store.append(row("t2", start: 2.5, end: 4))
            try store.appendWords([word("t2", 0, "again", 2.5, 3, [0.1, 0.8, 0.05, 0.05]), word("t2", 1, "please", 3, 4, []),
                                   word("t1", 0, "hello", 0, 1), word("t1", 1, "there", 1.2, 2)])
            XCTAssertEqual(try store.words(transcriptID: "t1").map(\.word), ["hello", "there"])
        }
        let store = try TranscriptStore(directory: directory)
        let words = try store.words(sessionID: "a")
        XCTAssertEqual(words.map(\.word), ["hello", "there", "again", "please"])
        XCTAssertEqual(words.map(\.position), [0, 1, 0, 1])
        XCTAssertEqual(words[2].probabilities, [0.1, 0.8, 0.05, 0.05])
        XCTAssertEqual(words[3].probabilities, [], "Missing diarizer frames are stored as NULL and read back as no evidence")
        XCTAssertEqual(words[1].startSeconds, 1.2)
        XCTAssertTrue(try store.words(sessionID: "other").isEmpty)
        XCTAssertEqual(try count("PRAGMA user_version"), 8)
    }

    func testInvalidWordBatchesAreRefusedWhole() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("t1"))
        let good = word("t1", 0, "hello", 1, 2)
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 1, "x", 2, 1.5)]), "end before start")
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 1, "x", .nan, 2)]), "non-finite time")
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 1, "x", 2, 3, [0.5, 0.5, 0, 0, 0])]), "five probabilities")
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 1, "x", 2, 3, [.infinity])]), "non-finite probability")
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 0, "x", 2, 3)]), "repeated position")
        XCTAssertThrowsError(try store.appendWords([good, word("t1", 1, "x", 0.5, 2)]), "start goes backwards")
        XCTAssertThrowsError(try store.appendWords([good, word("missing", 0, "x", 2, 3)]), "no such transcript")
        XCTAssertThrowsError(try store.appendWords((0...20_000).map { word("t1", $0, "x", Double($0), Double($0)) }), "batch too large")
        XCTAssertTrue(try store.words(transcriptID: "t1").isEmpty, "A refused batch stores nothing, not even its valid words")
        try store.appendWords([good])
        XCTAssertEqual(try store.words(transcriptID: "t1").count, 1)
    }

    func testDeletingRowsRemovesTheirWordsWithoutOrphans() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "a")); try store.append(row("a2", session: "a", start: 3, end: 4))
        try store.append(row("b1", session: "b"))
        var dictation = row("d1", session: "d"); dictation.mode = "dictation"; try store.append(dictation)
        try store.appendWords([word("a1", 0, "hello", 0, 1), word("a1", 1, "there", 1, 2), word("a2", 0, "again", 3, 4), word("b1", 0, "other", 0, 1)])
        try store.deleteTranscripts(ids: ["a1"])
        XCTAssertEqual(try store.words(sessionID: "a").map(\.word), ["again"])
        try store.clearHistory()
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_words"), 2, "Clearing dictation history leaves session words alone")
        try store.deleteSession(id: "a")
        XCTAssertEqual(try store.words(sessionID: "b").map(\.word), ["other"])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_words WHERE transcript_id NOT IN (SELECT id FROM transcripts)"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_words"), 1)
    }

    func testRelabelSessionKeepsCleanedTextAndRowIDs() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("t1", start: 0, end: 1, text: "First person"))
        try store.append(row("t2", start: 1, end: 3, text: "so we should ship it"))
        try store.append(row("other", session: "b"))
        try store.setReadableText("First person.", for: try XCTUnwrap(store.read(id: "t1")))
        try store.setReadableText("So we should ship it.", for: try XCTUnwrap(store.read(id: "t2")))
        try store.setTitle(sessionID: "a", title: "Standup")
        try store.label(sessionID: "a", speakerID: "speaker-1", name: "Gina")
        try store.appendEvent(CaptureEvent(sessionID: "a", kind: "started", detail: "Started"))
        try store.appendWords([word("t1", 0, "First", 0, 0.5), word("t1", 1, "person", 0.5, 1),
                               word("t2", 0, "so", 1, 1.25), word("t2", 1, "we", 1.25, 1.5), word("t2", 2, "should", 1.5, 2),
                               word("t2", 3, "ship", 2, 2.5), word("t2", 4, "it", 2.5, 3), word("other", 0, "other", 0, 1)])
        var seen: [String] = []
        // The pass hears a second voice from "ship" on, inside row t2.
        let changed = try store.relabelSession("a") { words in
            seen = words.map(\.word)
            return ["speaker-2", "speaker-2", "speaker-2", "speaker-2", "speaker-2", "speaker-1", "speaker-1"]
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(seen, ["First", "person", "so", "we", "should", "ship", "it"])
        let rows = try store.session(id: "a")
        XCTAssertEqual(rows.map(\.text), ["First person.", "So we should", "ship it."], "Every row keeps its cleaned text, and a split row shares it out")
        XCTAssertEqual(rows.map(\.speakerID), ["speaker-2", "speaker-2", "speaker-1"])
        XCTAssertEqual(rows.map(\.speakerLabel), [nil, nil, "Gina"])
        XCTAssertEqual(rows[0].id, "t1")
        XCTAssertFalse(rows[1...].contains { $0.id == "t2" })
        XCTAssertEqual(rows.map(\.startSeconds), [0, 1, 2])
        XCTAssertEqual(rows.map(\.endSeconds), [1, 2, 3])
        XCTAssertEqual(rows.map(\.startedAt), Array(repeating: Date(timeIntervalSince1970: 100), count: 3))
        XCTAssertEqual(try store.words(transcriptID: rows[1].id).map(\.word), ["so", "we", "should"])
        XCTAssertEqual(try store.words(transcriptID: rows[2].id).map(\.position), [0, 1])
        XCTAssertEqual(try store.words(sessionID: "a").map(\.word), seen)
        XCTAssertEqual(try store.sessionSummary(id: "a")?.title, "Standup")
        XCTAssertEqual(try store.labels(sessionID: "a"), ["speaker-1": "Gina"])
        XCTAssertEqual(try store.events(sessionID: "a").count, 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_words WHERE transcript_id NOT IN (SELECT id FROM transcripts)"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_readable WHERE transcript_id NOT IN (SELECT id FROM transcripts)"), 0)
        let other = try XCTUnwrap(store.read(id: "other"))
        XCTAssertEqual(other.text, "hello there")
        XCTAssertEqual(other.speakerID, "speaker-1")

        // Relabeling again from the same speakers changes nothing.
        try store.relabelSession("a") { _ in ["speaker-2", "speaker-2", "speaker-2", "speaker-2", "speaker-2", "speaker-1", "speaker-1"] }
        XCTAssertEqual(try store.session(id: "a").map(\.id), rows.map(\.id))
        XCTAssertEqual(try store.session(id: "a").map(\.text), rows.map(\.text))
    }

    func testRelabelSessionLeavesSessionsWithoutWordsAndDeletedSessionsAlone() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("old", session: "c", text: "recorded before words were kept"))
        let noWords: ([StoredWord]) -> [String?] = { _ in
            XCTFail("No words to relabel")
            return []
        }
        XCTAssertFalse(try store.relabelSession("c", speakers: noWords))
        XCTAssertEqual(try store.read(id: "old")?.speakerID, "speaker-1")

        try store.append(row("t1", start: 0, end: 1, text: "one two"))
        try store.appendWords([word("t1", 0, "one", 0, 0.5), word("t1", 1, "two", 0.5, 1)])
        // Deleting the session while its speakers are worked out leaves nothing to write back to.
        try store.relabelSession("a") { _ in
            try? store.deleteSession(id: "a")
            return ["speaker-2", "speaker-3"]
        }
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcripts WHERE session_id = 'a'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_words"), 0)
        XCTAssertFalse(try store.relabelSession("a", speakers: noWords))
    }

    func testOpeningAnOlderDatabaseAddsTheWordTableAndKeepsRows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("transcripts.sqlite3").path
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation'))); INSERT INTO transcripts VALUES('old','s',100,0,2,'kept','speaker-1','ambient'); PRAGMA user_version=4;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.read(id: "old")?.text, "kept")
        XCTAssertTrue(try store.words(sessionID: "s").isEmpty)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='transcript_words'"), 1)
        XCTAssertEqual(try count("PRAGMA user_version"), 8)
    }
}
