import XCTest
import SQLite3
@testable import JotCore

/// Opening the database: format 8, and format 7 that 0.2.5 and 0.2.6 wrote, open with every row; any other format is replaced by an empty database, and nothing else in the directory is touched.
final class DatabaseFormatTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-format-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var databaseURL: URL { directory.appendingPathComponent("transcripts.sqlite3") }

    // The statements the stores ran before the schema moved into TranscriptStore alone, copied verbatim. SQLite keeps each CREATE statement's text, so a file built from them is what an installed build wrote.
    /// What TranscriptStore ran on main at 407470f: its schema, then the change feed.
    private static let formerTranscriptSchema = "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation'))); CREATE INDEX IF NOT EXISTS transcript_absolute_time ON transcripts((started_at + start_seconds) DESC, id DESC); CREATE INDEX IF NOT EXISTS transcript_session_time ON transcripts(session_id, (started_at + start_seconds), id); CREATE TABLE IF NOT EXISTS speaker_labels (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(session_id,speaker_id)); CREATE TABLE IF NOT EXISTS capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, duration_seconds REAL CHECK(duration_seconds >= 0)); CREATE INDEX IF NOT EXISTS capture_event_time ON capture_events(timestamp DESC,id DESC); CREATE INDEX IF NOT EXISTS capture_event_session_time ON capture_events(session_id,timestamp DESC,id DESC); CREATE TABLE IF NOT EXISTS session_titles (session_id TEXT PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE IF NOT EXISTS transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL); CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds); CREATE TABLE IF NOT EXISTS transcript_words (transcript_id TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE, position INTEGER NOT NULL, word TEXT NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, p1 REAL, p2 REAL, p3 REAL, p4 REAL, PRIMARY KEY(transcript_id, position)); CREATE TABLE IF NOT EXISTS dictation_attempts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL, text TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified','delivered','discarded')), has_gap INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL); CREATE INDEX IF NOT EXISTS dictation_attempt_state_time ON dictation_attempts(state, updated_at DESC);"
    private static let formerChangeSchema = "CREATE TABLE IF NOT EXISTS transcript_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, transcript_id TEXT NOT NULL UNIQUE REFERENCES transcripts(id) ON DELETE CASCADE ON UPDATE CASCADE);\nCREATE TRIGGER IF NOT EXISTS transcript_change_insert AFTER INSERT ON transcripts BEGIN\n  DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;\nCREATE TRIGGER IF NOT EXISTS transcript_change_update AFTER UPDATE ON transcripts\n  WHEN OLD.text IS NOT NEW.text OR OLD.speaker_id IS NOT NEW.speaker_id OR OLD.session_id IS NOT NEW.session_id OR OLD.started_at IS NOT NEW.started_at\n    OR OLD.start_seconds IS NOT NEW.start_seconds OR OLD.end_seconds IS NOT NEW.end_seconds OR OLD.mode IS NOT NEW.mode BEGIN\n  DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;\nCREATE TRIGGER IF NOT EXISTS transcript_change_readable_insert AFTER INSERT ON transcript_readable BEGIN\n  DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;\nCREATE TRIGGER IF NOT EXISTS transcript_change_readable_update AFTER UPDATE ON transcript_readable WHEN OLD.text IS NOT NEW.text BEGIN\n  DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;"
    /// What SpeakerPassStore and PeopleStore then ran over their own connections.
    private static let formerSpeakerPassSchema = "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds);"
    private static let formerPeopleSchema = "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL, embedding BLOB NOT NULL, sample_count INTEGER NOT NULL CHECK(sample_count >= 1), created_at REAL NOT NULL, updated_at REAL NOT NULL);"

    /// One of everything a user has: ambient rows with words and cleaned text, a named speaker, a title, an event, a dictation row and its failed attempt, a speaker pass, and a remembered voice.
    private static let rows = """
        INSERT INTO transcripts VALUES('a1','s1',100,0,2,'um hello there','speaker-1','ambient');
        INSERT INTO transcripts VALUES('a2','s1',100,3,5,'general kenobi','speaker-2','ambient');
        INSERT INTO transcripts VALUES('d1','d-session',200,0,1,'take a note',NULL,'dictation');
        INSERT INTO transcript_readable VALUES('a1','Hello there.');
        INSERT INTO transcript_words VALUES('a1',0,'um',0,0.4,0.9,0.05,0.05,0);
        INSERT INTO transcript_words VALUES('a1',1,'hello',0.5,1,0.9,0.05,0.05,0);
        INSERT INTO transcript_words VALUES('a1',2,'there',1.1,2,NULL,NULL,NULL,NULL);
        INSERT INTO transcript_words VALUES('a2',0,'general',3,4,0.1,0.8,0.1,0);
        INSERT INTO transcript_words VALUES('a2',1,'kenobi',4,5,0.1,0.8,0.1,0);
        INSERT INTO speaker_labels VALUES('s1','speaker-1','Gina');
        INSERT INTO session_titles VALUES('s1','Standup');
        INSERT INTO capture_events VALUES('e1','s1',100,'started','Ambient microphone capture started.',NULL);
        INSERT INTO dictation_attempts VALUES('attempt','d-session',200,201,'take a note','deliveryFailed',1,202);
        INSERT INTO session_speakers VALUES('s1','speaker-1',X'0000803F00000000',2.0);
        INSERT INTO session_segments VALUES('s1','speaker-1',0,2);
        INSERT INTO people VALUES('p1','Ada',X'000000000000803F',3,50,60);
        """

    /// Builds the file the way the former stores did: TranscriptStore's schema and change feed, then the speaker pass and people tables, each on its own connection.
    private func writeFormerDatabase(version: Int, rows: String = rows, at url: URL? = nil) {
        for sql in [Self.formerTranscriptSchema, Self.formerChangeSchema + "\nPRAGMA user_version=8;", Self.formerSpeakerPassSchema, Self.formerPeopleSchema,
                    rows + "PRAGMA user_version=\(version);"] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open((url ?? databaseURL).path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
        }
    }

    /// Every object in the file, every row of every table, and the format, as text.
    private func dump(_ url: URL? = nil) throws -> [String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open((url ?? databaseURL).path, &db) == SQLITE_OK else { throw StoreError.database("open failed") }
        func rows(_ sql: String) throws -> [String] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.database(String(cString: sqlite3_errmsg(db))) }
            var result: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(stmt)).map { index -> String in
                    switch sqlite3_column_type(stmt, index) {
                    case SQLITE_NULL: return "NULL"
                    case SQLITE_BLOB: return (sqlite3_column_blob(stmt, index).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, index))) } ?? Data()).map { String(format: "%02x", $0) }.joined()
                    default: return String(cString: sqlite3_column_text(stmt, index))
                    }
                }.joined(separator: "|"))
            }
            return result
        }
        var result = try rows("PRAGMA user_version")
        result += try rows("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
        for table in try rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            result += try rows("SELECT '\(table)', * FROM \"\(table)\" ORDER BY rowid")
        }
        return result
    }

    func testDatabaseTheFormerStoresWroteOpensWithEveryRowAndNoRebuild() throws {
        writeFormerDatabase(version: 8)
        let before = try dump()
        XCTAssertEqual(before.first, "8")
        do {
            let store = try TranscriptStore(directory: directory)
            XCTAssertFalse(store.replacedDatabase)
            let pass = try SpeakerPassStore(sharing: store)
            let people = try PeopleStore(sharing: store)
            XCTAssertEqual(try store.session(id: "s1").map(\.text), ["Hello there.", "general kenobi"])
            XCTAssertEqual(try store.session(id: "s1").map(\.speakerLabel), ["Gina", nil])
            XCTAssertEqual(try store.sessions().map(\.title), ["Standup"])
            XCTAssertEqual(try store.recent(mode: "dictation").map(\.id), ["d1"])
            XCTAssertEqual(try store.words(sessionID: "s1").map(\.word), ["um", "hello", "there", "general", "kenobi"])
            XCTAssertEqual(try store.words(sessionID: "s1").map(\.probabilities.count), [4, 4, 0, 4, 4])
            XCTAssertEqual(try store.events(sessionID: "s1").map(\.id), ["e1"])
            let attempt = try XCTUnwrap(store.latestRecoverableDictationAttempt())
            XCTAssertEqual(attempt.text, "take a note")
            XCTAssertTrue(attempt.hasGap)
            XCTAssertEqual(try store.changes(since: 0).rows.map(\.transcript.id), ["a2", "d1", "a1"], "The feed the former triggers kept, cleaned row last")
            XCTAssertEqual(try pass.speakers(sessionID: "s1"), [.init(speakerID: "speaker-1", embedding: [1, 0], durationSeconds: 2)])
            XCTAssertEqual(try pass.segments(sessionID: "s1"), [.init(speakerID: "speaker-1", start: 0, end: 2)])
            XCTAssertEqual(try people.list().map(\.name), ["Ada"])
            XCTAssertEqual(try people.list().first?.sampleCount, 3)
        }
        XCTAssertEqual(try dump(), before, "Opening changed no object, row, or format")
    }

    /// What 0.2.6 ran, copied verbatim from its TranscriptStore, SpeakerPassStore and PeopleStore: format 7 has no change feed and still has the older session index.
    private static let release026Schemas = [
        "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation'))); CREATE INDEX IF NOT EXISTS transcript_absolute_time ON transcripts((started_at + start_seconds) DESC, id DESC); CREATE INDEX IF NOT EXISTS transcript_session ON transcripts(session_id); CREATE TABLE IF NOT EXISTS speaker_labels (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(session_id,speaker_id)); CREATE TABLE IF NOT EXISTS capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, duration_seconds REAL CHECK(duration_seconds >= 0)); CREATE INDEX IF NOT EXISTS capture_event_time ON capture_events(timestamp DESC,id DESC); CREATE INDEX IF NOT EXISTS capture_event_session_time ON capture_events(session_id,timestamp DESC,id DESC); CREATE TABLE IF NOT EXISTS session_titles (session_id TEXT PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE IF NOT EXISTS transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL); CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds); CREATE TABLE IF NOT EXISTS transcript_words (transcript_id TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE, position INTEGER NOT NULL, word TEXT NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, p1 REAL, p2 REAL, p3 REAL, p4 REAL, PRIMARY KEY(transcript_id, position)); CREATE TABLE IF NOT EXISTS dictation_attempts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL, text TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified','delivered','discarded')), has_gap INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL); CREATE INDEX IF NOT EXISTS dictation_attempt_state_time ON dictation_attempts(state, updated_at DESC); PRAGMA user_version=7;",
        "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds);",
        "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL, embedding BLOB NOT NULL, sample_count INTEGER NOT NULL CHECK(sample_count >= 1), created_at REAL NOT NULL, updated_at REAL NOT NULL);",
    ]

    /// The installed 0.2.6 wrote format 7, so this is the file the first launch of this build opens.
    func testDatabaseRelease026WroteOpensWithEveryRowAndGainsOnlyTheChangeFeed() throws {
        for sql in Self.release026Schemas + [Self.rows + "PRAGMA user_version=7;"] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
        }
        let before = try dump()
        XCTAssertEqual(before.first, "7")
        do {
            let store = try TranscriptStore(directory: directory)
            XCTAssertFalse(store.replacedDatabase)
            let pass = try SpeakerPassStore(sharing: store)
            let people = try PeopleStore(sharing: store)
            XCTAssertEqual(try store.session(id: "s1").map(\.text), ["Hello there.", "general kenobi"])
            XCTAssertEqual(try store.session(id: "s1").map(\.speakerLabel), ["Gina", nil])
            XCTAssertEqual(try store.sessions().map(\.title), ["Standup"])
            XCTAssertEqual(try store.recent(mode: "dictation").map(\.id), ["d1"])
            XCTAssertEqual(try store.words(sessionID: "s1").map(\.word), ["um", "hello", "there", "general", "kenobi"])
            XCTAssertEqual(try store.events(sessionID: "s1").map(\.id), ["e1"])
            XCTAssertTrue(try XCTUnwrap(store.latestRecoverableDictationAttempt()).hasGap)
            XCTAssertEqual(try store.changes(since: 0).rows.map(\.transcript.id), ["a1", "a2", "d1"], "Saved rows join the feed once, in spoken order")
            XCTAssertEqual(try pass.speakers(sessionID: "s1"), [.init(speakerID: "speaker-1", embedding: [1, 0], durationSeconds: 2)])
            XCTAssertEqual(try pass.segments(sessionID: "s1"), [.init(speakerID: "speaker-1", start: 0, end: 2)])
            XCTAssertEqual(try people.list().map(\.name), ["Ada"])
        }
        let after = try dump()
        XCTAssertEqual(after.first, "8")
        XCTAssertEqual(Set(before.dropFirst()).subtracting(after), [], "Every object and row 0.2.6 wrote is still there, unchanged")
        XCTAssertFalse(try TranscriptStore(directory: directory).replacedDatabase)
        XCTAssertEqual(try dump(), after, "Reopening changes nothing and enqueues no row twice")
    }

    func testNewDatabaseHasExactlyTheFormerSchema() throws {
        let former = directory.appendingPathComponent("former.sqlite3")
        writeFormerDatabase(version: 8, rows: "", at: former)
        let store = try TranscriptStore(directory: directory)
        XCTAssertFalse(store.replacedDatabase, "An empty directory is a new database, not a replaced one")
        XCTAssertEqual(try dump(), try dump(former))
    }

    func testAnyOtherFormatIsReplacedWithAnEmptyDatabaseAndNothingElseIsTouched() throws {
        for version in [0, 6, 9] {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let neighbors: [String: Data] = ["audio/s1.f32": Data([1, 2, 3, 4]), "service.sock": Data("socket".utf8),
                "transcripts.sqlite3.bak": Data("backup".utf8), "other.sqlite3": Data("other".utf8), "other.sqlite3-wal": Data("other wal".utf8),
                "notes.txt": Data("notes".utf8)]
            for (path, data) in neighbors {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            writeFormerDatabase(version: version)
            do {
                let store = try TranscriptStore(directory: directory)
                XCTAssertTrue(store.replacedDatabase, "format \(version)")
                XCTAssertEqual(try store.count(), 0)
                XCTAssertTrue(try store.sessions().isEmpty)
                XCTAssertNil(try store.latestRecoverableDictationAttempt())
                XCTAssertTrue(try PeopleStore(sharing: store).list().isEmpty)
                XCTAssertTrue(try SpeakerPassStore(sharing: store).segments(sessionID: "s1").isEmpty)
            }
            XCTAssertEqual(try dump().first, "8")
            let fresh = directory.appendingPathComponent("fresh")
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            _ = try TranscriptStore(directory: fresh)
            XCTAssertEqual(try dump(), try dump(fresh.appendingPathComponent("transcripts.sqlite3")), "The replacement is a new, empty database")
            try FileManager.default.removeItem(at: fresh)
            for (path, data) in neighbors {
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)), data, "\(path) at format \(version)")
            }
            let left = Set(try FileManager.default.subpathsOfDirectory(atPath: directory.path)).subtracting(TranscriptStore.files(of: databaseURL).map { ($0 as NSString).lastPathComponent })
            XCTAssertEqual(left, Set(neighbors.keys).union(["audio"]), "format \(version)")
            XCTAssertFalse(try TranscriptStore(directory: directory).replacedDatabase, "A replaced database opens as it is from then on")
        }
    }

    func testDeletingTheDatabaseRemovesOnlyItsOwnFilesAndNeverADirectory() throws {
        let names = ["transcripts.sqlite3", "transcripts.sqlite3-wal", "transcripts.sqlite3-shm", "transcripts.sqlite3-journal",
                     "transcripts.sqlite3.bak", "transcripts.sqlite3-wal.keep", "other.sqlite3-shm"]
        for name in names { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
        try TranscriptStore.deleteFiles(of: databaseURL)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(names.dropFirst(3)))
        try TranscriptStore.deleteFiles(of: databaseURL)

        let walDirectory = directory.appendingPathComponent("transcripts.sqlite3-wal")
        try FileManager.default.createDirectory(at: walDirectory, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: walDirectory.appendingPathComponent("inside"))
        XCTAssertThrowsError(try TranscriptStore.deleteFiles(of: databaseURL))
        XCTAssertEqual(try Data(contentsOf: walDirectory.appendingPathComponent("inside")), Data("kept".utf8))
    }
}
