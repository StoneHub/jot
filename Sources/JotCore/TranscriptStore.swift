import Foundation
import SQLite3

public enum JotPaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jot", isDirectory: true)
    }
    public static var socketURL: URL { directory.appendingPathComponent("service.sock") }
}

public struct Transcript: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sessionID: String
    public var startedAt: Date
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var speakerID: String?
    public var mode: String
    public var speakerLabel: String?

    public init(id: String = UUID().uuidString, sessionID: String, startedAt: Date,
                startSeconds: Double, endSeconds: Double, text: String,
                speakerID: String? = nil, mode: String, speakerLabel: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.startedAt = startedAt
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.text = text
        self.speakerID = speakerID; self.mode = mode; self.speakerLabel = speakerLabel
    }
}

/// One row from the change feed: the row as `transcripts.recent` returns it, plus the change sequence that delivered it. Encodes flat, so a reader sees the transcript's own keys and `sequence`.
public struct TranscriptChange: Codable, Sendable, Equatable {
    public var transcript: Transcript
    public var sequence: Int64
    public init(_ transcript: Transcript, sequence: Int64) { self.transcript = transcript; self.sequence = sequence }

    private enum Keys: String, CodingKey { case sequence }
    public init(from decoder: Decoder) throws {
        transcript = try Transcript(from: decoder)
        sequence = try decoder.container(keyedBy: Keys.self).decode(Int64.self, forKey: .sequence)
    }
    public func encode(to encoder: Encoder) throws {
        try transcript.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(sequence, forKey: .sequence)
    }
}

/// One `transcripts.since` page. Pass `cursor` back to read what changed after it; `hasMore` asks for the next page now, otherwise wait `pollAfterSeconds`.
public struct TranscriptChanges: Codable, Sendable, Equatable {
    /// How long a caught-up follower should wait before polling again. The server does not refuse faster polls; a caught-up poll costs one counter read.
    public static let caughtUpPollSeconds = 2.0
    public var rows: [TranscriptChange]
    public var cursor: Int64
    public var hasMore: Bool
    /// The cursor was ahead of this store, as after its database was recreated, so the page starts from the beginning.
    public var reset: Bool
    public var pollAfterSeconds: Double
    public init(rows: [TranscriptChange], cursor: Int64, hasMore: Bool, reset: Bool = false) {
        self.rows = rows; self.cursor = cursor; self.hasMore = hasMore; self.reset = reset
        pollAfterSeconds = hasMore ? 0 : Self.caughtUpPollSeconds
    }
}

public struct TranscriptSession: Codable, Sendable, Identifiable, Equatable {
    public let sessionID: String
    public let startedAt: Date
    public let lastTranscriptAt: Date
    public let transcriptCount: Int
    /// Set by meeting mode or a rename; nil for an untitled ambient session.
    public var title: String?
    public var id: String { sessionID }
    public var durationSeconds: Double { lastTranscriptAt.timeIntervalSince(startedAt) }
    public init(sessionID: String, startedAt: Date, lastTranscriptAt: Date, transcriptCount: Int, title: String? = nil) {
        self.sessionID = sessionID; self.startedAt = startedAt; self.lastTranscriptAt = lastTranscriptAt
        self.transcriptCount = transcriptCount; self.title = title
    }
}

/// Capture lifecycle metadata only. Callers must not put transcript text or audio in detail.
public struct CaptureEvent: Codable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var timestamp: Date
    public var kind: String
    public var detail: String
    public var durationSeconds: Double?

    public init(id: String = UUID().uuidString, sessionID: String, timestamp: Date = Date(),
                kind: String, detail: String, durationSeconds: Double? = nil) {
        self.id = id; self.sessionID = sessionID; self.timestamp = timestamp
        self.kind = kind; self.detail = detail; self.durationSeconds = durationSeconds
    }
}

/// One recognized word behind an ambient transcript row: its timing in the session's clock and the diarizer's four speaker probabilities. No audio.
public struct StoredWord: Codable, Sendable {
    public var transcriptID: String
    public var position: Int
    public var word: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var probabilities: [Float]
    public init(transcriptID: String, position: Int, word: String, startSeconds: Double, endSeconds: Double, probabilities: [Float]) {
        self.transcriptID = transcriptID; self.position = position; self.word = word
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.probabilities = probabilities
    }
}

public struct StoreMetrics: Codable, Sendable {
    public let transcriptCount: Int
    public let sessionCount: Int
    public let databaseBytes: Int64
}

public enum StoreError: Error, LocalizedError {
    case database(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .database(let value), .invalid(let value): return value }
    }
}

/// All database access is serialized by the connection's lock. No raw audio is stored.
public final class TranscriptStore: @unchecked Sendable {
    /// The format this build reads and writes, kept in the file's `PRAGMA user_version`.
    static let format: Int64 = 8
    private let db: SQLiteConnection
    let databaseURL: URL
    /// True when the file held a format this build does not read, and opening replaced it with an empty database.
    public let replacedDatabase: Bool

    public init(directory: URL = JotPaths.directory) throws {
        try preparePrivateDirectory(directory)
        databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw StoreError.invalid("Transcript database must be a regular file owned by this user")
            }
        }
        var connection = try SQLiteConnection(url: databaseURL)
        let version = try connection.integer("PRAGMA user_version")
        let empty = try connection.integer("SELECT COUNT(*) FROM sqlite_master") == 0
        // Format 7 is the one older format still opened: 0.2.5 and 0.2.6 wrote it, so an installed database may still hold it. Format 8 only added the change feed, which the schema below creates and the backfill fills. Any other format, older or newer, is deleted and recreated empty.
        replacedDatabase = !empty && version != Self.format && version != 7
        if replacedDatabase {
            connection.close()
            try Self.deleteFiles(of: databaseURL)
            connection = try SQLiteConnection(url: databaseURL)
        }
        db = connection
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute(Self.schema)
        try db.execute(Self.changeSchema)
        if version == 7 && !replacedDatabase {
            // Rows saved at format 7 join the change feed once, in spoken order. The triggers keep it current from then on.
            try db.transaction { try db.execute("INSERT INTO transcript_changes(transcript_id) SELECT t.id FROM transcripts t WHERE NOT EXISTS (SELECT 1 FROM transcript_changes c WHERE c.transcript_id = t.id) ORDER BY (t.started_at + t.start_seconds), t.id") }
        }
        try db.execute("PRAGMA user_version=\(Self.format)")
    }

    /// The database file and the WAL and shared-memory files SQLite keeps beside it.
    static func files(of databaseURL: URL) -> [String] {
        [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
    }

    /// Deletes this store's own files and nothing else: the paths come from its location, never a pattern, and unlink removes one file, never a directory.
    static func deleteFiles(of databaseURL: URL) throws {
        for path in files(of: databaseURL) where unlink(path) != 0 && errno != ENOENT {
            throw StoreError.database("Could not delete \((path as NSString).lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Every table and index. Opening an existing database changes nothing, since each statement is IF NOT EXISTS. SpeakerPassStore and PeopleStore use their tables over connections of their own.
    /// A session speaker's embedding is 256 Float32 little-endian, the size WeSpeaker produces, and its duration is that speaker's total speech in the session. A person's embedding is the same kind of vector at unit length, and sample_count is how many were averaged into it.
    private static let schema = """
        CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation')));
        CREATE INDEX IF NOT EXISTS transcript_absolute_time ON transcripts((started_at + start_seconds) DESC, id DESC);
        CREATE INDEX IF NOT EXISTS transcript_session_time ON transcripts(session_id, (started_at + start_seconds), id);
        CREATE TABLE IF NOT EXISTS speaker_labels (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(session_id,speaker_id));
        CREATE TABLE IF NOT EXISTS capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, duration_seconds REAL CHECK(duration_seconds >= 0));
        CREATE INDEX IF NOT EXISTS capture_event_time ON capture_events(timestamp DESC,id DESC);
        CREATE INDEX IF NOT EXISTS capture_event_session_time ON capture_events(session_id,timestamp DESC,id DESC);
        CREATE TABLE IF NOT EXISTS session_titles (session_id TEXT PRIMARY KEY, title TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id));
        CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds));
        CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds);
        CREATE TABLE IF NOT EXISTS transcript_words (transcript_id TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE, position INTEGER NOT NULL, word TEXT NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, p1 REAL, p2 REAL, p3 REAL, p4 REAL, PRIMARY KEY(transcript_id, position));
        CREATE TABLE IF NOT EXISTS dictation_attempts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL, text TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified','delivered','discarded')), has_gap INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS dictation_attempt_state_time ON dictation_attempts(state, updated_at DESC);
        CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL, embedding BLOB NOT NULL, sample_count INTEGER NOT NULL CHECK(sample_count >= 1), created_at REAL NOT NULL, updated_at REAL NOT NULL);
        """

    /// The change feed behind `transcripts.since`: one entry per row, holding the sequence number of the row's latest visible change. AUTOINCREMENT never reuses a number, so a row that is added, cleaned, or relabeled moves past every cursor already handed out, and its entry goes when the row is deleted. Entries hold ids and numbers only, no text.
    private static let changeSchema = """
        CREATE TABLE IF NOT EXISTS transcript_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, transcript_id TEXT NOT NULL UNIQUE REFERENCES transcripts(id) ON DELETE CASCADE ON UPDATE CASCADE);
        CREATE TRIGGER IF NOT EXISTS transcript_change_insert AFTER INSERT ON transcripts BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_update AFTER UPDATE ON transcripts
          WHEN OLD.text IS NOT NEW.text OR OLD.speaker_id IS NOT NEW.speaker_id OR OLD.session_id IS NOT NEW.session_id OR OLD.started_at IS NOT NEW.started_at
            OR OLD.start_seconds IS NOT NEW.start_seconds OR OLD.end_seconds IS NOT NEW.end_seconds OR OLD.mode IS NOT NEW.mode BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_readable_insert AFTER INSERT ON transcript_readable BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_readable_update AFTER UPDATE ON transcript_readable WHEN OLD.text IS NOT NEW.text BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;
        """

    /// Rows added or changed after `cursor`, oldest change first, each row at most once with its current text. A cleanup rewrite or speaker relabel returns the same row id again with the new text; it is never a second row. The cursor is a change sequence, not a row id or time, so it survives cleanup rewrites and session rotation, and a session filter only narrows what is returned. A cursor ahead of this store (a recreated database) restarts from the beginning and sets `reset`. A caught-up poll reads one counter row and returns without a query.
    public func changes(since cursor: Int64 = 0, sessionID: String? = nil, limit: Int = 50) throws -> TranscriptChanges {
        guard cursor >= 0 else { throw StoreError.invalid("Cursor must be a nonnegative integer") }
        return try db.locked {
            let head = try changeHead()
            let reset = cursor > head
            let start = reset ? 0 : cursor
            guard start < head else { return TranscriptChanges(rows: [], cursor: head, hasMore: false, reset: reset) }
            let size = clamp(limit)
            let stmt = try db.prepare("SELECT c.seq,t.id,t.session_id,t.started_at,t.start_seconds,t.end_seconds,COALESCE(r.text,t.text),t.speaker_id,t.mode,l.name FROM transcript_changes c JOIN transcripts t ON t.id=c.transcript_id LEFT JOIN transcript_readable r ON r.transcript_id=t.id LEFT JOIN speaker_labels l ON t.session_id=l.session_id AND t.speaker_id=l.speaker_id WHERE c.seq > ? AND c.seq <= ?\(sessionID == nil ? "" : " AND t.session_id = ?") ORDER BY c.seq LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, start)
            sqlite3_bind_int64(stmt, 2, head)
            var index: Int32 = 3
            if let sessionID { db.bind(sessionID, to: index, in: stmt); index += 1 }
            sqlite3_bind_int(stmt, index, Int32(size + 1))
            var rows: [TranscriptChange] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                rows.append(TranscriptChange(Transcript(id: db.column(stmt, 1)!, sessionID: db.column(stmt, 2)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), startSeconds: sqlite3_column_double(stmt, 4), endSeconds: sqlite3_column_double(stmt, 5), text: db.column(stmt, 6)!, speakerID: db.column(stmt, 7), mode: db.column(stmt, 8)!, speakerLabel: db.column(stmt, 9)), sequence: sqlite3_column_int64(stmt, 0)))
            }
            let hasMore = rows.count > size
            if hasMore { rows.removeLast(rows.count - size) }
            return TranscriptChanges(rows: rows, cursor: hasMore ? rows[rows.count - 1].sequence : head, hasMore: hasMore, reset: reset)
        }
    }

    /// The newest change sequence ever assigned; 0 before the first row. Caller holds the lock.
    private func changeHead() throws -> Int64 {
        let stmt = try db.prepare("SELECT seq FROM sqlite_sequence WHERE name = 'transcript_changes'")
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return 0 }
        guard status == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_int64(stmt, 0)
    }

    public func append(_ transcript: Transcript) throws {
        guard !transcript.id.isEmpty, !transcript.sessionID.isEmpty,
              transcript.startSeconds.isFinite, transcript.endSeconds.isFinite,
              transcript.startedAt.timeIntervalSince1970.isFinite,
              transcript.startSeconds >= 0, transcript.endSeconds >= transcript.startSeconds,
              ["ambient", "dictation"].contains(transcript.mode),
              transcript.text.utf8.count <= 1_000_000 else { throw StoreError.invalid("Invalid transcript fields") }
        try db.locked { try insert(transcript) }
    }

    /// Saves delivery state and recognized text for force-quit recovery. Raw audio is
    /// intentionally never written by this API.
    public func saveDictationAttempt(_ attempt: DictationAttempt) throws {
        guard !attempt.id.isEmpty, !attempt.sessionID.isEmpty,
              attempt.startedAt.timeIntervalSince1970.isFinite,
              attempt.endedAt?.timeIntervalSince1970.isFinite ?? true,
              attempt.endedAt.map({ $0 >= attempt.startedAt }) ?? true,
              attempt.updatedAt.timeIntervalSince1970.isFinite,
              attempt.text.utf8.count <= 1_000_000 else {
            throw StoreError.invalid("Invalid dictation attempt")
        }
        try db.locked {
            let stmt = try db.prepare("INSERT INTO dictation_attempts(id,session_id,started_at,ended_at,text,state,has_gap,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id,started_at=excluded.started_at,ended_at=excluded.ended_at,text=excluded.text,state=excluded.state,has_gap=excluded.has_gap,updated_at=excluded.updated_at")
            defer { sqlite3_finalize(stmt) }
            db.bind(attempt.id, to: 1, in: stmt); db.bind(attempt.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, attempt.startedAt.timeIntervalSince1970)
            if let endedAt = attempt.endedAt { sqlite3_bind_double(stmt, 4, endedAt.timeIntervalSince1970) }
            else { sqlite3_bind_null(stmt, 4) }
            db.bind(attempt.text, to: 5, in: stmt); db.bind(attempt.state.rawValue, to: 6, in: stmt)
            sqlite3_bind_int(stmt, 7, attempt.hasGap ? 1 : 0)
            sqlite3_bind_double(stmt, 8, attempt.updatedAt.timeIntervalSince1970)
            try db.finish(stmt)
        }
    }

    public func latestRecoverableDictationAttempt() throws -> DictationAttempt? {
        try db.locked {
            let stmt = try db.prepare("SELECT id,session_id,started_at,ended_at,text,state,has_gap,updated_at FROM dictation_attempts WHERE state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified') AND length(trim(text)) > 0 ORDER BY updated_at DESC,id DESC LIMIT 1")
            defer { sqlite3_finalize(stmt) }
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let state = db.column(stmt, 5).flatMap(DictationAttempt.State.init(rawValue:)) else { throw db.error() }
            return DictationAttempt(id: db.column(stmt, 0)!, sessionID: db.column(stmt, 1)!,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                text: db.column(stmt, 4)!, state: state,
                hasGap: sqlite3_column_int(stmt, 6) != 0,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)))
        }
    }

    /// A process exit cannot recover unsaved raw audio, but already recognized text
    /// remains a retryable delivery instead of looking like an active capture forever.
    /// A hold saves the words as recognized, so `converting` turns them into the text
    /// to insert in the same update that ends the hold; no attempt is converted twice.
    public func finalizeInterruptedDictationAttempts(converting: (String) -> String) throws {
        try db.locked {
            let select = try db.prepare("SELECT id,text FROM dictation_attempts WHERE state IN ('capturing','recognizing')")
            defer { sqlite3_finalize(select) }
            var interrupted: [(id: String, text: String)] = []
            while true {
                let status = sqlite3_step(select)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                interrupted.append((db.column(select, 0)!, db.column(select, 1)!))
            }
            for attempt in interrupted {
                let update = try db.prepare("UPDATE dictation_attempts SET text=?,state='deliveryFailed',has_gap=1,ended_at=COALESCE(ended_at,updated_at) WHERE id=?")
                defer { sqlite3_finalize(update) }
                db.bind(converting(attempt.text), to: 1, in: update)
                db.bind(attempt.id, to: 2, in: update)
                try db.finish(update)
            }
        }
    }

    public func deleteDictationAttempt(id: String) throws {
        try db.locked {
            try deletion {
                let stmt = try db.prepare("DELETE FROM dictation_attempts WHERE id = ?")
                defer { sqlite3_finalize(stmt) }
                db.bind(id, to: 1, in: stmt); try db.finish(stmt)
            }
        }
    }

    /// Recognized speech overlapping an absolute time window, in spoken order. When
    /// word timing exists it clips at the word boundary; older rows are included whole
    /// rather than risking a missing edge.
    public func recoveryText(from lowerBound: Date, through upperBound: Date) throws -> String {
        guard lowerBound.timeIntervalSince1970.isFinite, upperBound.timeIntervalSince1970.isFinite,
              upperBound >= lowerBound else { throw StoreError.invalid("Invalid recovery window") }
        return try db.locked {
            let stmt = try db.prepare("SELECT t.id,t.started_at,COALESCE(r.text,t.text) FROM transcripts t LEFT JOIN transcript_readable r ON r.transcript_id=t.id WHERE t.mode='ambient' AND (t.started_at+t.end_seconds) > ? AND (t.started_at+t.start_seconds) < ? ORDER BY (t.started_at+t.start_seconds),t.id")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, upperBound.timeIntervalSince1970)
            var pieces: [String] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let transcriptID = db.column(stmt, 0)!
                let sessionStart = sqlite3_column_double(stmt, 1)
                let fallback = db.column(stmt, 2)!
                let evidenceStmt = try db.prepare("SELECT 1 FROM transcript_words WHERE transcript_id=? LIMIT 1")
                db.bind(transcriptID, to: 1, in: evidenceStmt)
                let evidenceStatus = sqlite3_step(evidenceStmt)
                guard evidenceStatus == SQLITE_ROW || evidenceStatus == SQLITE_DONE else {
                    sqlite3_finalize(evidenceStmt); throw db.error()
                }
                let hasWordEvidence = evidenceStatus == SQLITE_ROW
                sqlite3_finalize(evidenceStmt)
                let wordStmt = try db.prepare("SELECT w.word FROM transcript_words w WHERE w.transcript_id=? AND (?+w.end_seconds) > ? AND (?+w.start_seconds) < ? ORDER BY w.position")
                db.bind(transcriptID, to: 1, in: wordStmt)
                sqlite3_bind_double(wordStmt, 2, sessionStart)
                sqlite3_bind_double(wordStmt, 3, lowerBound.timeIntervalSince1970)
                sqlite3_bind_double(wordStmt, 4, sessionStart)
                sqlite3_bind_double(wordStmt, 5, upperBound.timeIntervalSince1970)
                var words: [String] = []
                while true {
                    let wordStatus = sqlite3_step(wordStmt)
                    if wordStatus == SQLITE_DONE { break }
                    guard wordStatus == SQLITE_ROW else { sqlite3_finalize(wordStmt); throw db.error() }
                    words.append(db.column(wordStmt, 0)!)
                }
                sqlite3_finalize(wordStmt)
                if !words.isEmpty { pieces.append(words.joined(separator: " ")) }
                else if !hasWordEvidence { pieces.append(fallback) }
            }
            return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func insert(_ transcript: Transcript) throws {
        try insert([transcript])
    }

    /// Caller holds the lock; one statement serves every row.
    private func insert(_ transcripts: [Transcript]) throws {
        let stmt = try db.prepare("INSERT INTO transcripts(id,session_id,started_at,start_seconds,end_seconds,text,speaker_id,mode) VALUES(?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        for transcript in transcripts {
            sqlite3_reset(stmt)
            db.bind(transcript.id, to: 1, in: stmt)
            db.bind(transcript.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, transcript.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, transcript.startSeconds)
            sqlite3_bind_double(stmt, 5, transcript.endSeconds)
            db.bind(transcript.text, to: 6, in: stmt)
            db.bind(transcript.speakerID, to: 7, in: stmt)
            db.bind(transcript.mode, to: 8, in: stmt)
            try db.finish(stmt)
        }
    }

    /// Relabels one finished session's ambient rows from one speaker per stored word. A row whose words keep one speaker keeps its id and cleaned text and takes that speaker; a row whose speaker changes inside it is replaced by one row per speaker, each with its words and its share of the cleaned text. Speaker names, the title, and events stay. `speakers` runs without the lock. The plan is written in batches, releasing the lock between them so a reader never waits long: a reader can see a partly relabeled session, but every row is consistent. False when the session has no stored words: it was deleted, or recorded before words were kept.
    @discardableResult
    public func relabelSession(_ id: String, speakers: ([StoredWord]) -> [String?]) throws -> Bool {
        let words = try words(sessionID: id)
        if words.isEmpty { return false }
        let readable = try readableTexts(sessionID: id)
        let plan = try RowRelabel(words: words, speakers: speakers(words), readable: readable)
        try inBatches(plan.kept) { try relabel($0, sessionID: id) }
        try inBatches(plan.splits) { try split($0, sessionID: id) }
        return true
    }

    /// How long a relabel batch may hold the lock before it commits.
    private static let relabelBatchWork = Duration.milliseconds(5)

    /// Writes a relabel plan a batch at a time. Each batch is one transaction that commits once about 5 ms of work is done. NSLock is not fair: a batch that takes the lock straight after the one before can keep a waiting reader, such as the main thread, out for several batches, so a millisecond's pause between batches lets it in.
    private func inBatches<Row>(_ rows: [Row], write: (Row) throws -> Void) throws {
        var next = 0
        while next < rows.count {
            try db.locked {
                try db.transaction {
                    let began = ContinuousClock.now
                    repeat {
                        try write(rows[next])
                        next += 1
                    } while next < rows.count && began.duration(to: .now) < Self.relabelBatchWork
                }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// Cleaned text by row id, for one session's rows that have it.
    public func readableTexts(sessionID: String) throws -> [String: String] {
        try db.locked {
            let stmt = try db.prepare("SELECT r.transcript_id,r.text FROM transcript_readable r JOIN transcripts t ON t.id = r.transcript_id WHERE t.session_id = ?")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            var result: [String: String] = [:]
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result[db.column(stmt, 0)!] = db.column(stmt, 1) ?? ""
            }
            return result
        }
    }

    /// A kept row takes its new speaker. A row that is gone, deleted with its session, changes nothing. Caller holds the lock and the transaction.
    private func relabel(_ row: (rowID: String, speaker: String?), sessionID: String) throws {
        let update = try db.prepare("UPDATE transcripts SET speaker_id=? WHERE id=? AND session_id=? AND mode='ambient'")
        defer { sqlite3_finalize(update) }
        db.bind(row.speaker, to: 1, in: update)
        db.bind(row.rowID, to: 2, in: update)
        db.bind(sessionID, to: 3, in: update)
        try db.finish(update)
    }

    /// A split row is deleted, which takes its words and cleaned text with it, and its pieces are inserted in its place. A row that is gone, deleted with its session, gets no pieces. Caller holds the lock and the transaction.
    private func split(_ split: RowRelabel.Split, sessionID: String) throws {
        let delete = try db.prepare("DELETE FROM transcripts WHERE id=? AND session_id=? AND mode='ambient' RETURNING started_at")
        defer { sqlite3_finalize(delete) }
        db.bind(split.rowID, to: 1, in: delete)
        db.bind(sessionID, to: 2, in: delete)
        let status = sqlite3_step(delete)
        if status == SQLITE_DONE { return }
        guard status == SQLITE_ROW else { throw db.error() }
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(delete, 0))
        // A statement left mid-row would keep the transaction from committing.
        sqlite3_reset(delete)
        var rows: [Transcript] = []
        var words: [StoredWord] = []
        var readable: [(transcriptID: String, text: String)] = []
        for piece in split.pieces {
            let row = Transcript(sessionID: sessionID, startedAt: startedAt, startSeconds: piece.start, endSeconds: piece.end, text: piece.text, speakerID: piece.speaker, mode: "ambient")
            var pieceWords = piece.words
            for index in pieceWords.indices {
                pieceWords[index].transcriptID = row.id
            }
            try validate(pieceWords)
            rows.append(row)
            words.append(contentsOf: pieceWords)
            if let text = piece.readable { readable.append((transcriptID: row.id, text: text)) }
        }
        try insert(rows)
        try insert(words)
        try insertReadable(readable)
    }

    /// Caller holds the lock and the transaction.
    private func insertReadable(_ texts: [(transcriptID: String, text: String)]) throws {
        let stmt = try db.prepare("INSERT INTO transcript_readable(transcript_id,text) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        for readable in texts {
            sqlite3_reset(stmt)
            db.bind(readable.transcriptID, to: 1, in: stmt)
            db.bind(readable.text, to: 2, in: stmt)
            try db.finish(stmt)
        }
    }

    /// A phrase may remove all the filler from one constituent row. Apply the
    /// complete edit atomically, only if every original row still exists unchanged.
    @discardableResult public func setReadablePhrase(_ texts: [String], for sources: [Transcript]) throws -> Bool {
        guard texts.count == sources.count, !sources.isEmpty,
              texts.reduce(0, { $0 + $1.utf8.count }) <= 1_000_000 else {
            throw StoreError.invalid("Invalid readable phrase")
        }
        return try db.locked {
            try db.transaction { () -> Bool in
                for source in sources {
                    let check = try db.prepare("SELECT 1 FROM transcripts WHERE id=? AND text=?")
                    db.bind(source.id, to: 1, in: check); db.bind(source.text, to: 2, in: check)
                    let exists = sqlite3_step(check) == SQLITE_ROW
                    sqlite3_finalize(check)
                    if !exists { return false }
                }
                for (source, text) in zip(sources, texts) {
                    let stmt = try db.prepare("INSERT OR REPLACE INTO transcript_readable(transcript_id,text) VALUES(?,?)")
                    db.bind(source.id, to: 1, in: stmt); db.bind(text, to: 2, in: stmt)
                    defer { sqlite3_finalize(stmt) }
                    try db.finish(stmt)
                }
                return true
            }
        }
    }

    /// The words one inference block produced, in one transaction. Each word must belong to a saved transcript; positions and start times must ascend within a transcript.
    public func appendWords(_ words: [StoredWord]) throws {
        guard words.count <= 20_000 else { throw StoreError.invalid("Too many words in one batch") }
        try validate(words)
        try db.locked { try db.transaction { try insert(words) } }
    }

    /// Every stored word of one session in time order, the input for regrouping or a later speaker pass.
    public func words(sessionID: String) throws -> [StoredWord] {
        try db.locked {
            let stmt = try db.prepare("SELECT w.transcript_id,w.position,w.word,w.start_seconds,w.end_seconds,w.p1,w.p2,w.p3,w.p4 FROM transcript_words w JOIN transcripts t ON t.id = w.transcript_id WHERE t.session_id = ? ORDER BY w.start_seconds,w.position")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            var result: [StoredWord] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let probabilities = (Int32(5)..<9).prefix { sqlite3_column_type(stmt, $0) != SQLITE_NULL }.map { Float(sqlite3_column_double(stmt, $0)) }
                result.append(StoredWord(transcriptID: db.column(stmt, 0)!, position: Int(sqlite3_column_int64(stmt, 1)), word: db.column(stmt, 2)!,
                    startSeconds: sqlite3_column_double(stmt, 3), endSeconds: sqlite3_column_double(stmt, 4), probabilities: probabilities))
            }
            return result
        }
    }

    private func validate(_ words: [StoredWord]) throws {
        var previous: StoredWord?
        for word in words {
            guard !word.transcriptID.isEmpty, word.word.utf8.count <= 1_000, word.position >= 0,
                  word.startSeconds.isFinite, word.endSeconds.isFinite, word.startSeconds >= 0, word.endSeconds >= word.startSeconds,
                  word.probabilities.count <= 4, word.probabilities.allSatisfy(\.isFinite) else { throw StoreError.invalid("Invalid word fields") }
            if let previous, previous.transcriptID == word.transcriptID {
                guard word.position > previous.position, word.startSeconds >= previous.startSeconds else { throw StoreError.invalid("Words must ascend within a transcript") }
            }
            previous = word
        }
    }

    /// Caller holds the lock and the transaction; the words were validated already.
    private func insert(_ words: [StoredWord]) throws {
        let stmt = try db.prepare("INSERT INTO transcript_words(transcript_id,position,word,start_seconds,end_seconds,p1,p2,p3,p4) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        for word in words {
            sqlite3_reset(stmt)
            db.bind(word.transcriptID, to: 1, in: stmt); sqlite3_bind_int64(stmt, 2, Int64(word.position)); db.bind(word.word, to: 3, in: stmt)
            sqlite3_bind_double(stmt, 4, word.startSeconds); sqlite3_bind_double(stmt, 5, word.endSeconds)
            for slot in 0..<4 {
                if slot < word.probabilities.count { sqlite3_bind_double(stmt, Int32(6 + slot), Double(word.probabilities[slot])) } else { sqlite3_bind_null(stmt, Int32(6 + slot)) }
            }
            try db.finish(stmt)
        }
    }


    /// Pass mode "dictation" or "ambient" to read one kind of row; nil reads both.
    public func search(_ query: String, mode: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try db.locked {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return try rows(where: "WHERE COALESCE(r.text,t.text) LIKE ? ESCAPE '\\'" + modeClause(mode), value: "%" + escaped + "%", limit: clamp(limit), offset: offset)
        }
    }

    public func appendEvent(_ event: CaptureEvent) throws {
        guard !event.id.isEmpty, !event.sessionID.isEmpty, !event.kind.isEmpty,
              event.kind.utf8.count <= 100, event.detail.utf8.count <= 2000,
              event.timestamp.timeIntervalSince1970.isFinite,
              event.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw StoreError.invalid("Invalid capture event fields") }
        try db.locked {
            let stmt = try db.prepare("INSERT INTO capture_events(id,session_id,timestamp,kind,detail,duration_seconds) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            db.bind(event.id, to: 1, in: stmt); db.bind(event.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, event.timestamp.timeIntervalSince1970)
            db.bind(event.kind, to: 4, in: stmt); db.bind(event.detail, to: 5, in: stmt)
            if let duration = event.durationSeconds { sqlite3_bind_double(stmt, 6, duration) } else { sqlite3_bind_null(stmt, 6) }
            try db.finish(stmt)
        }
    }

    public func events(sessionID: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [CaptureEvent] {
        try db.locked {
            let clause = sessionID == nil ? "" : "WHERE session_id = ?"
            let stmt = try db.prepare("SELECT id,session_id,timestamp,kind,detail,duration_seconds FROM capture_events \(clause) ORDER BY timestamp DESC,id DESC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let sessionID { db.bind(sessionID, to: index, in: stmt); index += 1 }
            sqlite3_bind_int(stmt, index, Int32(clamp(limit)))
            sqlite3_bind_int64(stmt, index + 1, Int64(max(0, offset)))
            var result: [CaptureEvent] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(CaptureEvent(id: db.column(stmt, 0)!, sessionID: db.column(stmt, 1)!,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    kind: db.column(stmt, 3)!, detail: db.column(stmt, 4)!,
                    durationSeconds: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)))
            }
            return result
        }
    }

    /// Bounded explicit-request context: recent dictation plus only the latest ambient session.
    /// Time predicates use the existing absolute-time index; the query never returns an entire session.
    public func suggestionContext(now: Date = Date()) throws -> SuggestionContext {
        try db.locked {
            let cutoff = now.addingTimeInterval(-30 * 60).timeIntervalSince1970
            let clause = """
                WHERE (t.started_at + t.start_seconds) >= CAST(? AS REAL)
                  AND (t.started_at + t.start_seconds) <= \(now.timeIntervalSince1970)
                  AND (t.mode = 'dictation' OR t.session_id = (
                    SELECT session_id FROM transcripts WHERE mode = 'ambient'
                      AND (started_at + start_seconds) <= \(now.timeIntervalSince1970)
                    ORDER BY (started_at + start_seconds) DESC, id DESC LIMIT 1))
                """
            let selected = try rows(where: clause, value: String(cutoff), limit: 100, offset: 0)
            var title: String?
            if let session = selected.first(where: { $0.mode == "ambient" })?.sessionID {
                let stmt = try db.prepare("SELECT title FROM session_titles WHERE session_id = ?")
                defer { sqlite3_finalize(stmt) }
                db.bind(session, to: 1, in: stmt)
                if sqlite3_step(stmt) == SQLITE_ROW { title = db.column(stmt, 0) }
            }
            return SuggestionContext(rows: selected, sessionTitle: title)
        }
    }

    /// Atomic readback of the selected rows only, including current cleaned text and speaker labels.
    public func suggestionRowsUnchanged(_ expected: [Transcript]) throws -> Bool {
        try db.locked {
            for row in expected {
                guard try rows(where: "WHERE t.id = ?", value: row.id, limit: 1, offset: 0).first == row else { return false }
            }
            return true
        }
    }

    public func recent(mode: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try db.locked { try rows(where: mode == nil ? "" : "WHERE 1=1" + modeClause(mode), value: nil, limit: clamp(limit), offset: offset) }
    }

    /// How many rows of one kind exist, for the sidebar counts; nil counts both kinds.
    public func count(mode: String? = nil) throws -> Int {
        try db.locked {
            let stmt = try db.prepare("SELECT COUNT(*) FROM transcripts t WHERE 1=1" + modeClause(mode))
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw db.error() }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func modeClause(_ mode: String?) -> String {
        switch mode { case "dictation"?: return " AND t.mode = 'dictation'"; case "ambient"?: return " AND t.mode = 'ambient'"; default: return "" }
    }

    /// Every row of one session in spoken order (absolute start time, then id), for Live, Sessions, and export. One query on the session's time index. Bounded at the newest 10,000 rows so a response stays inside the socket frame limit.
    public func session(id: String) throws -> [Transcript] {
        try db.locked {
            let newestFirst = try rows(where: "WHERE t.session_id = ?", value: id, limit: 10_000, offset: 0)
            return newestFirst.reversed()
        }
    }

    public func read(id: String) throws -> Transcript? {
        try db.locked { try rows(where: "WHERE t.id = ?", value: id, limit: 1, offset: 0).first }
    }

    /// Ambient and meeting captures only. Each Fn dictation carries its own session id and belongs in History, not here.
    public func sessions(limit: Int = 50) throws -> [TranscriptSession] {
        try db.locked {
            let stmt = try db.prepare("\(Self.sessionSelect) GROUP BY t.session_id ORDER BY MAX(t.started_at + t.end_seconds) DESC, t.session_id LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clamp(limit)))
            var result: [TranscriptSession] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(session(from: stmt))
            }
            return result
        }
    }

    /// One session by id with no list limit, so export still finds a session older than the newest 200. Ambient only, like sessions().
    public func sessionSummary(id: String) throws -> TranscriptSession? {
        try db.locked {
            let stmt = try db.prepare("\(Self.sessionSelect) AND t.session_id = ? GROUP BY t.session_id")
            defer { sqlite3_finalize(stmt) }
            db.bind(id, to: 1, in: stmt)
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw db.error() }
            return session(from: stmt)
        }
    }

    private static let sessionSelect = "SELECT t.session_id, MIN(t.started_at), MAX(t.started_at + t.end_seconds), COUNT(*), s.title FROM transcripts t LEFT JOIN session_titles s ON s.session_id = t.session_id WHERE t.mode = 'ambient'"
    private func session(from stmt: OpaquePointer) -> TranscriptSession {
        TranscriptSession(sessionID: db.column(stmt, 0)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), lastTranscriptAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), transcriptCount: Int(sqlite3_column_int64(stmt, 3)), title: db.column(stmt, 4))
    }

    /// A title names a session for the Sessions list and export file; an empty title removes it.
    public func setTitle(sessionID: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.locked {
            let stmt = try db.prepare(trimmed.isEmpty ? "DELETE FROM session_titles WHERE session_id = ?" : "INSERT INTO session_titles(session_id,title) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET title=excluded.title")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            if !trimmed.isEmpty { db.bind(String(trimmed.prefix(200)), to: 2, in: stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw db.error() }
        }
    }

    /// Labels are per session. Remembering the voice behind a label is a separate, explicit step through PeopleStore.
    public func label(sessionID: String, speakerID: String, name: String) throws {
        guard !sessionID.isEmpty, !speakerID.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw StoreError.invalid("Session, speaker, and a name of at most 200 characters are required") }
        try db.locked {
            let stmt = try db.prepare("INSERT INTO speaker_labels(session_id,speaker_id,name) VALUES(?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET name=excluded.name")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt); db.bind(speakerID, to: 2, in: stmt); db.bind(name, to: 3, in: stmt)
            try db.finish(stmt)
        }
    }

    /// The names given so far in one session, by speaker id.
    public func labels(sessionID: String) throws -> [String: String] {
        try db.locked {
            let stmt = try db.prepare("SELECT speaker_id,name FROM speaker_labels WHERE session_id = ?")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            var result: [String: String] = [:]
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result[db.column(stmt, 0)!] = db.column(stmt, 1)!
            }
            return result
        }
    }

    /// Clears the dictation rows History alone owns. Ambient rows belong to their session and are deleted from Sessions.
    public func clearHistory() throws {
        try db.locked {
            try deletion {
                try db.execute("DELETE FROM dictation_attempts")
                for table in ["session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                    try db.execute("DELETE FROM \(table) WHERE session_id IN (SELECT session_id FROM transcripts WHERE mode = 'dictation') AND session_id NOT IN (SELECT session_id FROM transcripts WHERE mode = 'ambient')")
                }
                try db.execute("DELETE FROM transcripts WHERE mode = 'dictation'")
            }
        }
    }

    public func deleteSession(id: String) throws {
        try db.locked {
            try deletion {
                let attempts = try db.prepare("DELETE FROM dictation_attempts WHERE session_id = ?")
                defer { sqlite3_finalize(attempts) }
                db.bind(id, to: 1, in: attempts); try db.finish(attempts)
                for table in ["transcripts", "session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                    let stmt = try db.prepare("DELETE FROM \(table) WHERE session_id = ?")
                    defer { sqlite3_finalize(stmt) }
                    db.bind(id, to: 1, in: stmt); try db.finish(stmt)
                }
            }
        }
    }

    /// A displayed history card may contain several original rows.
    public func deleteTranscripts(ids: [String]) throws {
        try db.locked {
            try deletion {
                var sessions = Set<String>()
                for id in Set(ids) {
                    let attempt = try db.prepare("DELETE FROM dictation_attempts WHERE id = ?")
                    defer { sqlite3_finalize(attempt) }
                    db.bind(id, to: 1, in: attempt); try db.finish(attempt)
                    let find = try db.prepare("SELECT session_id FROM transcripts WHERE id = ?")
                    defer { sqlite3_finalize(find) }
                    db.bind(id, to: 1, in: find)
                    let status = sqlite3_step(find)
                    if status == SQLITE_ROW { sessions.insert(db.column(find, 0)!) }
                    else if status != SQLITE_DONE { throw db.error() }
                    let stmt = try db.prepare("DELETE FROM transcripts WHERE id = ?")
                    defer { sqlite3_finalize(stmt) }
                    db.bind(id, to: 1, in: stmt); try db.finish(stmt)
                }
                for session in sessions {
                    for table in ["session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                        let stmt = try db.prepare("DELETE FROM \(table) WHERE session_id = ? AND NOT EXISTS (SELECT 1 FROM transcripts WHERE session_id = ?)")
                        defer { sqlite3_finalize(stmt) }
                        db.bind(session, to: 1, in: stmt); db.bind(session, to: 2, in: stmt); try db.finish(stmt)
                    }
                }
            }
        }
    }

    private func deletion(_ body: () throws -> Void) throws {
        try db.transaction(body)
        // Reclaim the WAL when no other reader holds it; deletion is already committed.
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func metrics() throws -> StoreMetrics {
        try db.locked {
            let stmt = try db.prepare("SELECT COUNT(*),COUNT(DISTINCT session_id) FROM transcripts")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw db.error() }
            var bytes: Int64 = 0
            for path in Self.files(of: databaseURL) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return StoreMetrics(transcriptCount: Int(sqlite3_column_int64(stmt, 0)), sessionCount: Int(sqlite3_column_int64(stmt, 1)), databaseBytes: bytes)
        }
    }

    private func rows(where clause: String, value: String?, limit: Int, offset: Int) throws -> [Transcript] {
        let stmt = try db.prepare("SELECT t.id,t.session_id,t.started_at,t.start_seconds,t.end_seconds,COALESCE(r.text,t.text),t.speaker_id,t.mode,l.name FROM transcripts t LEFT JOIN transcript_readable r ON r.transcript_id=t.id LEFT JOIN speaker_labels l ON t.session_id=l.session_id AND t.speaker_id=l.speaker_id \(clause) ORDER BY (t.started_at + t.start_seconds) DESC,t.id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        if let value { db.bind(value, to: index, in: stmt); index += 1 }
        sqlite3_bind_int(stmt, index, Int32(limit))
        sqlite3_bind_int64(stmt, index + 1, Int64(max(0, offset)))
        var result: [Transcript] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw db.error() }
            result.append(Transcript(id: db.column(stmt, 0)!, sessionID: db.column(stmt, 1)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), startSeconds: sqlite3_column_double(stmt, 3), endSeconds: sqlite3_column_double(stmt, 4), text: db.column(stmt, 5)!, speakerID: db.column(stmt, 6), mode: db.column(stmt, 7)!, speakerLabel: db.column(stmt, 8)))
        }
        return result
    }

    private func clamp(_ limit: Int) -> Int { max(1, min(200, limit)) }
}

/// Refuse symlinks and foreign ownership; only this user's processes may access the service data.
func preparePrivateDirectory(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw StoreError.invalid("Service directory must be a directory owned by this user") }
    } else {
        guard errno == ENOENT else { throw StoreError.invalid("Cannot inspect service directory") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    guard chmod(url.path, 0o700) == 0 else { throw StoreError.invalid("Cannot restrict service directory permissions") }
}
