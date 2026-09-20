import Foundation
import SQLite3

public enum JotPaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jot", isDirectory: true)
    }
    public static var socketURL: URL { directory.appendingPathComponent("service.sock") }
}

public struct Transcript: Codable, Sendable, Identifiable {
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

public struct TranscriptSession: Codable, Sendable, Identifiable {
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

/// All database access is serialized by an internal lock. No raw audio is stored.
public final class TranscriptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let databaseURL: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open transcript database"
            if let db { sqlite3_close(db) }; db = nil
            throw StoreError.database(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation'))); CREATE INDEX IF NOT EXISTS transcript_absolute_time ON transcripts((started_at + start_seconds) DESC, id DESC); CREATE INDEX IF NOT EXISTS transcript_session ON transcripts(session_id); CREATE TABLE IF NOT EXISTS speaker_labels (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(session_id,speaker_id)); CREATE TABLE IF NOT EXISTS capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, duration_seconds REAL CHECK(duration_seconds >= 0)); CREATE INDEX IF NOT EXISTS capture_event_time ON capture_events(timestamp DESC,id DESC); CREATE INDEX IF NOT EXISTS capture_event_session_time ON capture_events(session_id,timestamp DESC,id DESC); CREATE TABLE IF NOT EXISTS session_titles (session_id TEXT PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE IF NOT EXISTS transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL); CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds); CREATE TABLE IF NOT EXISTS transcript_words (transcript_id TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE, position INTEGER NOT NULL, word TEXT NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, p1 REAL, p2 REAL, p3 REAL, p4 REAL, PRIMARY KEY(transcript_id, position)); CREATE TABLE IF NOT EXISTS dictation_attempts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL, text TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified','delivered','discarded')), has_gap INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL); CREATE INDEX IF NOT EXISTS dictation_attempt_state_time ON dictation_attempts(state, updated_at DESC);")
            if try !hasColumn("has_gap", in: "dictation_attempts") {
                try execute("ALTER TABLE dictation_attempts ADD COLUMN has_gap INTEGER NOT NULL DEFAULT 0")
            }
            try execute("PRAGMA user_version=7")
        } catch {
            sqlite3_close(db); db = nil; throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func append(_ transcript: Transcript) throws {
        guard !transcript.id.isEmpty, !transcript.sessionID.isEmpty,
              transcript.startSeconds.isFinite, transcript.endSeconds.isFinite,
              transcript.startedAt.timeIntervalSince1970.isFinite,
              transcript.startSeconds >= 0, transcript.endSeconds >= transcript.startSeconds,
              ["ambient", "dictation"].contains(transcript.mode),
              transcript.text.utf8.count <= 1_000_000 else { throw StoreError.invalid("Invalid transcript fields") }
        try locked { try insert(transcript) }
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
        try locked {
            let stmt = try prepare("INSERT INTO dictation_attempts(id,session_id,started_at,ended_at,text,state,has_gap,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id,started_at=excluded.started_at,ended_at=excluded.ended_at,text=excluded.text,state=excluded.state,has_gap=excluded.has_gap,updated_at=excluded.updated_at")
            defer { sqlite3_finalize(stmt) }
            bind(attempt.id, to: 1, in: stmt); bind(attempt.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, attempt.startedAt.timeIntervalSince1970)
            if let endedAt = attempt.endedAt { sqlite3_bind_double(stmt, 4, endedAt.timeIntervalSince1970) }
            else { sqlite3_bind_null(stmt, 4) }
            bind(attempt.text, to: 5, in: stmt); bind(attempt.state.rawValue, to: 6, in: stmt)
            sqlite3_bind_int(stmt, 7, attempt.hasGap ? 1 : 0)
            sqlite3_bind_double(stmt, 8, attempt.updatedAt.timeIntervalSince1970)
            try finish(stmt)
        }
    }

    public func latestRecoverableDictationAttempt() throws -> DictationAttempt? {
        try locked {
            let stmt = try prepare("SELECT id,session_id,started_at,ended_at,text,state,has_gap,updated_at FROM dictation_attempts WHERE state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified') AND length(trim(text)) > 0 ORDER BY updated_at DESC,id DESC LIMIT 1")
            defer { sqlite3_finalize(stmt) }
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let state = column(stmt, 5).flatMap(DictationAttempt.State.init(rawValue:)) else { throw error() }
            return DictationAttempt(id: column(stmt, 0)!, sessionID: column(stmt, 1)!,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                text: column(stmt, 4)!, state: state,
                hasGap: sqlite3_column_int(stmt, 6) != 0,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)))
        }
    }

    /// A process exit cannot recover unsaved raw audio, but already recognized text
    /// remains a retryable delivery instead of looking like an active capture forever.
    public func finalizeInterruptedDictationAttempts() throws {
        try locked {
            let stmt = try prepare("UPDATE dictation_attempts SET state='deliveryFailed',has_gap=1,ended_at=COALESCE(ended_at,updated_at) WHERE state IN ('capturing','recognizing')")
            defer { sqlite3_finalize(stmt) }
            try finish(stmt)
        }
    }

    public func deleteDictationAttempt(id: String) throws {
        try locked {
            try deletion {
                let stmt = try prepare("DELETE FROM dictation_attempts WHERE id = ?")
                defer { sqlite3_finalize(stmt) }
                bind(id, to: 1, in: stmt); try finish(stmt)
            }
        }
    }

    /// Recognized speech overlapping an absolute time window, in spoken order. When
    /// word timing exists it clips at the word boundary; older rows are included whole
    /// rather than risking a missing edge.
    public func recoveryText(from lowerBound: Date, through upperBound: Date) throws -> String {
        guard lowerBound.timeIntervalSince1970.isFinite, upperBound.timeIntervalSince1970.isFinite,
              upperBound >= lowerBound else { throw StoreError.invalid("Invalid recovery window") }
        return try locked {
            let stmt = try prepare("SELECT t.id,t.started_at,COALESCE(r.text,t.text) FROM transcripts t LEFT JOIN transcript_readable r ON r.transcript_id=t.id WHERE t.mode='ambient' AND (t.started_at+t.end_seconds) > ? AND (t.started_at+t.start_seconds) < ? ORDER BY (t.started_at+t.start_seconds),t.id")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, upperBound.timeIntervalSince1970)
            var pieces: [String] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                let transcriptID = column(stmt, 0)!
                let sessionStart = sqlite3_column_double(stmt, 1)
                let fallback = column(stmt, 2)!
                let evidenceStmt = try prepare("SELECT 1 FROM transcript_words WHERE transcript_id=? LIMIT 1")
                bind(transcriptID, to: 1, in: evidenceStmt)
                let evidenceStatus = sqlite3_step(evidenceStmt)
                guard evidenceStatus == SQLITE_ROW || evidenceStatus == SQLITE_DONE else {
                    sqlite3_finalize(evidenceStmt); throw error()
                }
                let hasWordEvidence = evidenceStatus == SQLITE_ROW
                sqlite3_finalize(evidenceStmt)
                let wordStmt = try prepare("SELECT w.word FROM transcript_words w WHERE w.transcript_id=? AND (?+w.end_seconds) > ? AND (?+w.start_seconds) < ? ORDER BY w.position")
                bind(transcriptID, to: 1, in: wordStmt)
                sqlite3_bind_double(wordStmt, 2, sessionStart)
                sqlite3_bind_double(wordStmt, 3, lowerBound.timeIntervalSince1970)
                sqlite3_bind_double(wordStmt, 4, sessionStart)
                sqlite3_bind_double(wordStmt, 5, upperBound.timeIntervalSince1970)
                var words: [String] = []
                while true {
                    let wordStatus = sqlite3_step(wordStmt)
                    if wordStatus == SQLITE_DONE { break }
                    guard wordStatus == SQLITE_ROW else { sqlite3_finalize(wordStmt); throw error() }
                    words.append(column(wordStmt, 0)!)
                }
                sqlite3_finalize(wordStmt)
                if !words.isEmpty { pieces.append(words.joined(separator: " ")) }
                else if !hasWordEvidence { pieces.append(fallback) }
            }
            return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func insert(_ transcript: Transcript) throws {
        let stmt = try prepare("INSERT INTO transcripts(id,session_id,started_at,start_seconds,end_seconds,text,speaker_id,mode) VALUES(?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(transcript.id, to: 1, in: stmt); bind(transcript.sessionID, to: 2, in: stmt)
        sqlite3_bind_double(stmt, 3, transcript.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, transcript.startSeconds); sqlite3_bind_double(stmt, 5, transcript.endSeconds)
        bind(transcript.text, to: 6, in: stmt); bind(transcript.speakerID, to: 7, in: stmt); bind(transcript.mode, to: 8, in: stmt)
        try finish(stmt)
    }

    /// Rebuilds one session's ambient rows from turns over its stored words in one transaction. Speaker names, title, and events stay; cleanup text (transcript_readable) goes with the old rows and is not re-run.
    public func replaceSession(sessionID: String, words: [StoredWord], turns: [SpeechTurn]) throws {
        guard !words.isEmpty else { throw StoreError.invalid("This session was recorded before Jot kept word timings; it cannot be regrouped.") }
        guard !turns.isEmpty, turns.allSatisfy({ !$0.wordRange.isEmpty && $0.wordRange.lowerBound >= 0 && $0.wordRange.upperBound <= words.count }) else { throw StoreError.invalid("Turns must cover stored words") }
        try locked {
            try deletion {
                let find = try prepare("SELECT MIN(started_at) FROM transcripts WHERE session_id = ? AND mode = 'ambient'")
                defer { sqlite3_finalize(find) }
                bind(sessionID, to: 1, in: find)
                guard sqlite3_step(find) == SQLITE_ROW, sqlite3_column_type(find, 0) != SQLITE_NULL else { throw StoreError.invalid("No saved session to regroup") }
                let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(find, 0))
                let clear = try prepare("DELETE FROM transcripts WHERE session_id = ? AND mode = 'ambient'")
                defer { sqlite3_finalize(clear) }
                bind(sessionID, to: 1, in: clear); try finish(clear)
                for turn in turns {
                    let transcript = Transcript(sessionID: sessionID, startedAt: startedAt, startSeconds: turn.start, endSeconds: turn.end, text: turn.text, speakerID: turn.speaker, mode: "ambient")
                    guard transcript.startSeconds >= 0, transcript.endSeconds >= transcript.startSeconds else { throw StoreError.invalid("Invalid transcript fields") }
                    let rebuilt = words[turn.wordRange].enumerated().map { StoredWord(transcriptID: transcript.id, position: $0.offset, word: $0.element.word, startSeconds: $0.element.startSeconds, endSeconds: $0.element.endSeconds, probabilities: $0.element.probabilities) }
                    try validate(rebuilt)
                    try insert(transcript); try insert(rebuilt)
                }
            }
        }
    }

    /// Derived display text only; source rows stay intact and deletion cascades to this text.
    public func setReadableText(_ text: String, for source: Transcript) throws {
        guard !text.isEmpty, text.utf8.count <= 1_000_000 else { throw StoreError.invalid("Invalid readable transcript") }
        try locked {
            let stmt = try prepare("INSERT OR REPLACE INTO transcript_readable(transcript_id,text) SELECT id,? FROM transcripts WHERE id=? AND text=?")
            defer { sqlite3_finalize(stmt) }
            bind(text, to: 1, in: stmt); bind(source.id, to: 2, in: stmt); bind(source.text, to: 3, in: stmt)
            try finish(stmt)
        }
    }

    /// The words one inference block produced, in one transaction. Each word must belong to a saved transcript; positions and start times must ascend within a transcript.
    public func appendWords(_ words: [StoredWord]) throws {
        guard words.count <= 20_000 else { throw StoreError.invalid("Too many words in one batch") }
        try validate(words)
        try locked {
            try execute("BEGIN IMMEDIATE")
            do { try insert(words); try execute("COMMIT") }
            catch { try? execute("ROLLBACK"); throw error }
        }
    }

    /// Every stored word of one session in time order, the input for regrouping or a later speaker pass.
    public func words(sessionID: String) throws -> [StoredWord] {
        try locked { try words(where: "JOIN transcripts t ON t.id = w.transcript_id WHERE t.session_id = ?", value: sessionID) }
    }

    public func words(transcriptID: String) throws -> [StoredWord] {
        try locked { try words(where: "WHERE w.transcript_id = ?", value: transcriptID) }
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
        let stmt = try prepare("INSERT INTO transcript_words(transcript_id,position,word,start_seconds,end_seconds,p1,p2,p3,p4) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        for word in words {
            sqlite3_reset(stmt)
            bind(word.transcriptID, to: 1, in: stmt); sqlite3_bind_int64(stmt, 2, Int64(word.position)); bind(word.word, to: 3, in: stmt)
            sqlite3_bind_double(stmt, 4, word.startSeconds); sqlite3_bind_double(stmt, 5, word.endSeconds)
            for slot in 0..<4 {
                if slot < word.probabilities.count { sqlite3_bind_double(stmt, Int32(6 + slot), Double(word.probabilities[slot])) } else { sqlite3_bind_null(stmt, Int32(6 + slot)) }
            }
            try finish(stmt)
        }
    }

    private func words(where clause: String, value: String) throws -> [StoredWord] {
        let stmt = try prepare("SELECT w.transcript_id,w.position,w.word,w.start_seconds,w.end_seconds,w.p1,w.p2,w.p3,w.p4 FROM transcript_words w \(clause) ORDER BY w.start_seconds,w.position")
        defer { sqlite3_finalize(stmt) }
        bind(value, to: 1, in: stmt)
        var result: [StoredWord] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            let probabilities = (Int32(5)..<9).prefix { sqlite3_column_type(stmt, $0) != SQLITE_NULL }.map { Float(sqlite3_column_double(stmt, $0)) }
            result.append(StoredWord(transcriptID: column(stmt, 0)!, position: Int(sqlite3_column_int64(stmt, 1)), word: column(stmt, 2)!,
                startSeconds: sqlite3_column_double(stmt, 3), endSeconds: sqlite3_column_double(stmt, 4), probabilities: probabilities))
        }
        return result
    }

    /// Pass mode "dictation" or "ambient" to read one kind of row; nil reads both.
    public func search(_ query: String, mode: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try locked {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return try rows(where: "WHERE COALESCE(r.text,t.text) LIKE ? ESCAPE '\\'" + modeClause(mode), value: "%" + escaped + "%", limit: limit, offset: offset)
        }
    }

    public func appendEvent(_ event: CaptureEvent) throws {
        guard !event.id.isEmpty, !event.sessionID.isEmpty, !event.kind.isEmpty,
              event.kind.utf8.count <= 100, event.detail.utf8.count <= 2000,
              event.timestamp.timeIntervalSince1970.isFinite,
              event.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw StoreError.invalid("Invalid capture event fields") }
        try locked {
            let stmt = try prepare("INSERT INTO capture_events(id,session_id,timestamp,kind,detail,duration_seconds) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            bind(event.id, to: 1, in: stmt); bind(event.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, event.timestamp.timeIntervalSince1970)
            bind(event.kind, to: 4, in: stmt); bind(event.detail, to: 5, in: stmt)
            if let duration = event.durationSeconds { sqlite3_bind_double(stmt, 6, duration) } else { sqlite3_bind_null(stmt, 6) }
            try finish(stmt)
        }
    }

    public func events(sessionID: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [CaptureEvent] {
        try locked {
            let clause = sessionID == nil ? "" : "WHERE session_id = ?"
            let stmt = try prepare("SELECT id,session_id,timestamp,kind,detail,duration_seconds FROM capture_events \(clause) ORDER BY timestamp DESC,id DESC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let sessionID { bind(sessionID, to: index, in: stmt); index += 1 }
            sqlite3_bind_int(stmt, index, Int32(clamp(limit)))
            sqlite3_bind_int64(stmt, index + 1, Int64(max(0, offset)))
            var result: [CaptureEvent] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                result.append(CaptureEvent(id: column(stmt, 0)!, sessionID: column(stmt, 1)!,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    kind: column(stmt, 3)!, detail: column(stmt, 4)!,
                    durationSeconds: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)))
            }
            return result
        }
    }

    public func recent(mode: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try locked { try rows(where: mode == nil ? "" : "WHERE 1=1" + modeClause(mode), value: nil, limit: limit, offset: offset) }
    }

    /// How many rows of one kind exist, for the sidebar counts; nil counts both kinds.
    public func count(mode: String? = nil) throws -> Int {
        try locked {
            let stmt = try prepare("SELECT COUNT(*) FROM transcripts t WHERE 1=1" + modeClause(mode))
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func modeClause(_ mode: String?) -> String {
        switch mode { case "dictation"?: return " AND t.mode = 'dictation'"; case "ambient"?: return " AND t.mode = 'ambient'"; default: return "" }
    }

    /// Every row of one session in chronological order, for export. Bounded at 10,000 rows so a response stays inside the socket frame limit.
    public func session(id: String) throws -> [Transcript] {
        try locked {
            var result: [Transcript] = []
            while result.count < 10_000 {
                let page = try rows(where: "WHERE t.session_id = ?", value: id, limit: 200, offset: result.count)
                result.append(contentsOf: page)
                if page.count < 200 { break }
            }
            return result.sorted { ($0.startSeconds, $0.id) < ($1.startSeconds, $1.id) }
        }
    }

    public func read(id: String) throws -> Transcript? {
        try locked { try rows(where: "WHERE t.id = ?", value: id, limit: 1, offset: 0).first }
    }

    /// Ambient and meeting captures only. Each Fn dictation carries its own session id and belongs in History, not here.
    public func sessions(limit: Int = 50) throws -> [TranscriptSession] {
        try locked {
            let stmt = try prepare("\(Self.sessionSelect) GROUP BY t.session_id ORDER BY MAX(t.started_at + t.end_seconds) DESC, t.session_id LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clamp(limit)))
            var result: [TranscriptSession] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                result.append(session(from: stmt))
            }
            return result
        }
    }

    /// One session by id with no list limit, so export still finds a session older than the newest 200. Ambient only, like sessions().
    public func sessionSummary(id: String) throws -> TranscriptSession? {
        try locked {
            let stmt = try prepare("\(Self.sessionSelect) AND t.session_id = ? GROUP BY t.session_id")
            defer { sqlite3_finalize(stmt) }
            bind(id, to: 1, in: stmt)
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw error() }
            return session(from: stmt)
        }
    }

    private static let sessionSelect = "SELECT t.session_id, MIN(t.started_at), MAX(t.started_at + t.end_seconds), COUNT(*), s.title FROM transcripts t LEFT JOIN session_titles s ON s.session_id = t.session_id WHERE t.mode = 'ambient'"
    private func session(from stmt: OpaquePointer) -> TranscriptSession {
        TranscriptSession(sessionID: column(stmt, 0)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), lastTranscriptAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), transcriptCount: Int(sqlite3_column_int64(stmt, 3)), title: column(stmt, 4))
    }

    /// A title names a session for the Sessions list and export file; an empty title removes it.
    public func setTitle(sessionID: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try locked {
            let stmt = try prepare(trimmed.isEmpty ? "DELETE FROM session_titles WHERE session_id = ?" : "INSERT INTO session_titles(session_id,title) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET title=excluded.title")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt)
            if !trimmed.isEmpty { bind(String(trimmed.prefix(200)), to: 2, in: stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
        }
    }

    /// Labels are per session. Remembering the voice behind a label is a separate, explicit step through PeopleStore.
    public func label(sessionID: String, speakerID: String, name: String) throws {
        guard !sessionID.isEmpty, !speakerID.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw StoreError.invalid("Session, speaker, and a name of at most 200 characters are required") }
        try locked {
            let stmt = try prepare("INSERT INTO speaker_labels(session_id,speaker_id,name) VALUES(?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET name=excluded.name")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt); bind(speakerID, to: 2, in: stmt); bind(name, to: 3, in: stmt)
            try finish(stmt)
        }
    }

    /// The names given so far in one session, by speaker id.
    public func labels(sessionID: String) throws -> [String: String] {
        try locked {
            let stmt = try prepare("SELECT speaker_id,name FROM speaker_labels WHERE session_id = ?")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt)
            var result: [String: String] = [:]
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                result[column(stmt, 0)!] = column(stmt, 1)!
            }
            return result
        }
    }

    /// Clears the dictation rows History alone owns. Ambient rows belong to their session and are deleted from Sessions.
    public func clearHistory() throws {
        try locked {
            try deletion {
                try execute("DELETE FROM dictation_attempts")
                for table in ["session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                    try execute("DELETE FROM \(table) WHERE session_id IN (SELECT session_id FROM transcripts WHERE mode = 'dictation') AND session_id NOT IN (SELECT session_id FROM transcripts WHERE mode = 'ambient')")
                }
                try execute("DELETE FROM transcripts WHERE mode = 'dictation'")
            }
        }
    }

    public func deleteSession(id: String) throws {
        try locked {
            try deletion {
                let attempts = try prepare("DELETE FROM dictation_attempts WHERE session_id = ?")
                bind(id, to: 1, in: attempts); try finish(attempts); sqlite3_finalize(attempts)
                for table in ["transcripts", "session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                    let stmt = try prepare("DELETE FROM \(table) WHERE session_id = ?")
                    defer { sqlite3_finalize(stmt) }
                    bind(id, to: 1, in: stmt); try finish(stmt)
                }
            }
        }
    }

    /// A displayed history card may contain several original rows.
    public func deleteTranscripts(ids: [String]) throws {
        try locked {
            try deletion {
                var sessions = Set<String>()
                for id in Set(ids) {
                    let attempt = try prepare("DELETE FROM dictation_attempts WHERE id = ?")
                    bind(id, to: 1, in: attempt); try finish(attempt); sqlite3_finalize(attempt)
                    let find = try prepare("SELECT session_id FROM transcripts WHERE id = ?")
                    defer { sqlite3_finalize(find) }
                    bind(id, to: 1, in: find)
                    let status = sqlite3_step(find)
                    if status == SQLITE_ROW { sessions.insert(column(find, 0)!) }
                    else if status != SQLITE_DONE { throw error() }
                    let stmt = try prepare("DELETE FROM transcripts WHERE id = ?")
                    defer { sqlite3_finalize(stmt) }
                    bind(id, to: 1, in: stmt); try finish(stmt)
                }
                for session in sessions {
                    for table in ["session_titles", "speaker_labels", "capture_events", "session_speakers", "session_segments"] {
                        let stmt = try prepare("DELETE FROM \(table) WHERE session_id = ? AND NOT EXISTS (SELECT 1 FROM transcripts WHERE session_id = ?)")
                        defer { sqlite3_finalize(stmt) }
                        bind(session, to: 1, in: stmt); bind(session, to: 2, in: stmt); try finish(stmt)
                    }
                }
            }
        }
    }

    private func deletion(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
        // Reclaim the WAL when no other reader holds it; deletion is already committed.
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func metrics() throws -> StoreMetrics {
        try locked {
            let stmt = try prepare("SELECT COUNT(*),COUNT(DISTINCT session_id) FROM transcripts")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
            var bytes: Int64 = 0
            for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return StoreMetrics(transcriptCount: Int(sqlite3_column_int64(stmt, 0)), sessionCount: Int(sqlite3_column_int64(stmt, 1)), databaseBytes: bytes)
        }
    }

    private func rows(where clause: String, value: String?, limit: Int, offset: Int) throws -> [Transcript] {
        let stmt = try prepare("SELECT t.id,t.session_id,t.started_at,t.start_seconds,t.end_seconds,COALESCE(r.text,t.text),t.speaker_id,t.mode,l.name FROM transcripts t LEFT JOIN transcript_readable r ON r.transcript_id=t.id LEFT JOIN speaker_labels l ON t.session_id=l.session_id AND t.speaker_id=l.speaker_id \(clause) ORDER BY (t.started_at + t.start_seconds) DESC,t.id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        if let value { bind(value, to: index, in: stmt); index += 1 }
        sqlite3_bind_int(stmt, index, Int32(clamp(limit)))
        sqlite3_bind_int64(stmt, index + 1, Int64(max(0, offset)))
        var result: [Transcript] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            result.append(Transcript(id: column(stmt, 0)!, sessionID: column(stmt, 1)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), startSeconds: sqlite3_column_double(stmt, 3), endSeconds: sqlite3_column_double(stmt, 4), text: column(stmt, 5)!, speakerID: column(stmt, 6), mode: column(stmt, 7)!, speakerLabel: column(stmt, 8)))
        }
        return result
    }

    private func clamp(_ limit: Int) -> Int { max(1, min(200, limit)) }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    private func error() -> StoreError { .database(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func hasColumn(_ name: String, in table: String) throws -> Bool {
        guard table == "dictation_attempts" else { throw StoreError.invalid("Unsupported schema lookup") }
        let stmt = try prepare("PRAGMA table_info(dictation_attempts)")
        defer { sqlite3_finalize(stmt) }
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return false }
            guard status == SQLITE_ROW else { throw error() }
            if column(stmt, 1) == name { return true }
        }
    }
    private func finish(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() } }
    private func bind(_ value: String?, to index: Int32, in stmt: OpaquePointer) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }
    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: bytes)
    }
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
