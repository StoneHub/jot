import XCTest
import SQLite3
@testable import JotCore

/// `transcripts.since`: a follower polling the change feed sees every row once, and a cleanup or relabel as the same row id again.
final class TranscriptChangesTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-changes-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, session: String, seconds: Double, text: String? = nil, speaker: String? = "speaker-1") -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: seconds, endSeconds: seconds + 1,
                   text: text ?? "raw \(id)", speakerID: speaker, mode: "ambient")
    }

    /// A follower that polls like an agent would every two seconds: it reads pages until caught up and keeps each text it was handed, by row id.
    private final class Follower {
        let store: TranscriptStore
        let sessionID: String?
        var cursor: Int64 = 0
        var deliveries: [String: [String]] = [:]
        var order: [String] = []
        init(_ store: TranscriptStore, sessionID: String? = nil) { self.store = store; self.sessionID = sessionID }

        @discardableResult func poll(limit: Int = 2, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
            var received = 0
            while true {
                let page = try store.changes(since: cursor, sessionID: sessionID, limit: limit)
                XCTAssertFalse(page.reset, file: file, line: line)
                XCTAssertLessThanOrEqual(page.rows.count, limit, file: file, line: line)
                XCTAssertEqual(Set(page.rows.map(\.transcript.id)).count, page.rows.count, "A page lists a row at most once", file: file, line: line)
                XCTAssertEqual(page.rows.map(\.sequence), page.rows.map(\.sequence).sorted(), file: file, line: line)
                XCTAssertGreaterThanOrEqual(page.cursor, cursor, file: file, line: line)
                for change in page.rows {
                    if deliveries[change.transcript.id] == nil { order.append(change.transcript.id) }
                    deliveries[change.transcript.id, default: []].append(change.transcript.text)
                }
                received += page.rows.count
                cursor = page.cursor
                XCTAssertEqual(page.pollAfterSeconds, page.hasMore ? 0 : TranscriptChanges.caughtUpPollSeconds, file: file, line: line)
                if !page.hasMore { return received }
            }
        }
    }

    func testPollingDeliversEveryRowOnceAcrossCleanupRewritesAndSessionRotation() throws {
        let store = try TranscriptStore(directory: directory)
        let follower = Follower(store)
        XCTAssertEqual(try follower.poll(), 0, "An empty store has nothing to deliver")
        XCTAssertEqual(follower.cursor, 0)

        let a1 = row("a1", session: "A", seconds: 0), a2 = row("a2", session: "A", seconds: 1), a3 = row("a3", session: "A", seconds: 2)
        for item in [a1, a2, a3] { try store.append(item) }
        XCTAssertEqual(try follower.poll(), 3)

        // Cleanup lands after the follower saw the recognized text: the same id comes back with cleaned text.
        try store.setReadableText("clean a1", for: a1)
        let a4 = row("a4", session: "A", seconds: 3)
        try store.append(a4)
        XCTAssertEqual(try follower.poll(), 2)

        // Cleanup that lands before the next poll folds into the row's first delivery.
        let a5 = row("a5", session: "A", seconds: 4)
        try store.append(a5)
        try store.setReadableText("clean a5", for: a5)
        XCTAssertEqual(try follower.poll(), 1)

        // Quiet ends session A and capture continues in session B; the cursor does not care.
        let b1 = row("b1", session: "B", seconds: 900), b2 = row("b2", session: "B", seconds: 901)
        try store.append(b1)
        XCTAssertEqual(try follower.poll(), 1)
        try store.append(b2)
        XCTAssertTrue(try store.setReadablePhrase(["clean b1", "clean b2"], for: [b1, b2]))
        // A late cleanup of the old session still arrives after rotation.
        try store.setReadableText("clean a3", for: a3)
        XCTAssertEqual(try follower.poll(), 3)

        let caughtUp = follower.cursor
        XCTAssertEqual(try follower.poll(), 0, "A caught-up poll returns nothing")
        XCTAssertEqual(follower.cursor, caughtUp)

        XCTAssertEqual(follower.order, ["a1", "a2", "a3", "a4", "a5", "b1", "b2"], "Every row is first delivered once, in the order it arrived")
        XCTAssertEqual(follower.deliveries, [
            "a1": ["raw a1", "clean a1"],
            "a2": ["raw a2"],
            "a3": ["raw a3", "clean a3"],
            "a4": ["raw a4"],
            "a5": ["clean a5"],
            "b1": ["raw b1", "clean b1"],
            "b2": ["clean b2"]
        ])

        // A follower that joins late with a session filter sees only that session, once, with current text.
        let late = Follower(store, sessionID: "B")
        XCTAssertEqual(try late.poll(limit: 1), 2)
        XCTAssertEqual(late.deliveries, ["b1": ["clean b1"], "b2": ["clean b2"]])
        XCTAssertEqual(late.cursor, caughtUp, "Rows of other sessions still advance a filtered cursor")
    }

    func testSpeakerRelabelIsAnUpdateAndAnUnchangedSpeakerIsNotRedelivered() throws {
        let store = try TranscriptStore(directory: directory)
        let a1 = row("a1", session: "A", seconds: 0)
        try store.append(a1)
        try store.appendWords([StoredWord(transcriptID: "a1", position: 0, word: "raw", startSeconds: 0, endSeconds: 0.4, probabilities: []),
                               StoredWord(transcriptID: "a1", position: 1, word: "a1", startSeconds: 0.5, endSeconds: 1, probabilities: [])])
        try store.label(sessionID: "A", speakerID: "speaker-2", name: "Gina")
        let follower = Follower(store)
        XCTAssertEqual(try follower.poll(), 1)

        XCTAssertTrue(try store.relabelSession("A") { $0.map { _ in "speaker-1" } })
        XCTAssertEqual(try follower.poll(), 0, "Writing the same speaker is not a change")

        XCTAssertTrue(try store.relabelSession("A") { $0.map { _ in "speaker-2" } })
        let page = try store.changes(since: follower.cursor)
        XCTAssertEqual(page.rows.map(\.transcript.id), ["a1"])
        XCTAssertEqual(page.rows.first?.transcript.speakerID, "speaker-2")
        XCTAssertEqual(page.rows.first?.transcript.speakerLabel, "Gina")
    }

    func testCursorAheadOfTheStoreRestartsFromTheBeginning() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0))
        let page = try store.changes(since: 500)
        XCTAssertTrue(page.reset)
        XCTAssertEqual(page.rows.map(\.transcript.id), ["a1"])
        XCTAssertEqual(page.cursor, 1)
        XCTAssertFalse(try store.changes(since: page.cursor).reset)
        XCTAssertThrowsError(try store.changes(since: -1))
    }

    func testDeletedRowsLeaveTheFeedAndNumbersAreNeverReused() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0))
        try store.append(row("b1", session: "B", seconds: 10))
        try store.deleteSession(id: "A")
        XCTAssertEqual(try store.changes(since: 0).rows.map(\.transcript.id), ["b1"])
        try store.append(row("c1", session: "C", seconds: 20))
        XCTAssertEqual(try store.changes(since: 2).rows.map(\.sequence), [3])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_changes"), 2, "A deleted row keeps no entry")
    }

    func testRowsSavedBeforeTheFeedJoinItInSpokenOrderOnce() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation')));
            CREATE TABLE transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL);
            INSERT INTO transcripts VALUES('later','s',100,5,6,'second','speaker-1','ambient');
            INSERT INTO transcripts VALUES('earlier','s',100,1,2,'first','speaker-1','ambient');
            INSERT INTO transcript_readable VALUES('earlier','First.');
            PRAGMA user_version=7;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = try TranscriptStore(directory: directory)
            let page = try store.changes(since: 0)
            XCTAssertEqual(page.rows.map(\.transcript.id), ["earlier", "later"])
            XCTAssertEqual(page.rows.map(\.transcript.text), ["First.", "second"])
            XCTAssertEqual(page.cursor, 2)
        }
        XCTAssertEqual(try count("PRAGMA user_version"), 8)
        let reopened = try TranscriptStore(directory: directory)
        XCTAssertEqual(try reopened.changes(since: 0).rows.map(\.sequence), [1, 2], "Reopening does not enqueue rows again")
    }

    func testChangeEncodesFlatWithTheTranscriptKeys() throws {
        let change = TranscriptChange(row("a1", session: "A", seconds: 0), sequence: 7)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(TranscriptChanges(rows: [change], cursor: 7, hasMore: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["cursor"] as? Int, 7)
        XCTAssertEqual(object["hasMore"] as? Bool, false)
        XCTAssertEqual(object["pollAfterSeconds"] as? Double, 2)
        let first = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["id"] as? String, "a1")
        XCTAssertEqual(first["text"] as? String, "raw a1")
        XCTAssertEqual(first["sequence"] as? Int, 7)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TranscriptChanges.self, from: data).rows, [change])
    }

    private func count(_ sql: String) throws -> Int {
        var db: OpaquePointer?; var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        guard sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database("query failed") }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
