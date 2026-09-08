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

public struct TranscriptSession: Codable, Sendable {
    public let sessionID: String
    public let startedAt: Date
    public let lastTranscriptAt: Date
    public let transcriptCount: Int
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
            try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation'))); CREATE INDEX IF NOT EXISTS transcript_absolute_time ON transcripts((started_at + start_seconds) DESC, id DESC); CREATE INDEX IF NOT EXISTS transcript_session ON transcripts(session_id); CREATE TABLE IF NOT EXISTS speaker_labels (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(session_id,speaker_id)); CREATE TABLE IF NOT EXISTS capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, duration_seconds REAL CHECK(duration_seconds >= 0)); CREATE INDEX IF NOT EXISTS capture_event_time ON capture_events(timestamp DESC,id DESC); CREATE INDEX IF NOT EXISTS capture_event_session_time ON capture_events(session_id,timestamp DESC,id DESC); PRAGMA user_version=2;")
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
        try locked {
            let stmt = try prepare("INSERT INTO transcripts(id,session_id,started_at,start_seconds,end_seconds,text,speaker_id,mode) VALUES(?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            bind(transcript.id, to: 1, in: stmt); bind(transcript.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, transcript.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, transcript.startSeconds); sqlite3_bind_double(stmt, 5, transcript.endSeconds)
            bind(transcript.text, to: 6, in: stmt); bind(transcript.speakerID, to: 7, in: stmt); bind(transcript.mode, to: 8, in: stmt)
            try finish(stmt)
        }
    }

    public func search(_ query: String, limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try locked {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return try rows(where: "WHERE t.text LIKE ? ESCAPE '\\'", value: "%" + escaped + "%", limit: limit, offset: offset)
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

    public func recent(limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
        try locked { try rows(where: "", value: nil, limit: limit, offset: offset) }
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

    public func sessions(limit: Int = 50) throws -> [TranscriptSession] {
        try locked {
            let stmt = try prepare("SELECT session_id, MIN(started_at), MAX(started_at + end_seconds), COUNT(*) FROM transcripts GROUP BY session_id ORDER BY MAX(started_at + end_seconds) DESC, session_id LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clamp(limit)))
            var result: [TranscriptSession] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                result.append(TranscriptSession(sessionID: column(stmt, 0)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), lastTranscriptAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), transcriptCount: Int(sqlite3_column_int64(stmt, 3))))
            }
            return result
        }
    }

    /// Labels apply only to one session; this does not enroll or recognize a voice.
    public func label(sessionID: String, speakerID: String, name: String) throws {
        guard !sessionID.isEmpty, !speakerID.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw StoreError.invalid("Session, speaker, and a name of at most 200 characters are required") }
        try locked {
            let stmt = try prepare("INSERT INTO speaker_labels(session_id,speaker_id,name) VALUES(?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET name=excluded.name")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt); bind(speakerID, to: 2, in: stmt); bind(name, to: 3, in: stmt)
            try finish(stmt)
        }
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
        let stmt = try prepare("SELECT t.id,t.session_id,t.started_at,t.start_seconds,t.end_seconds,t.text,t.speaker_id,t.mode,l.name FROM transcripts t LEFT JOIN speaker_labels l ON t.session_id=l.session_id AND t.speaker_id=l.speaker_id \(clause) ORDER BY (t.started_at + t.start_seconds) DESC,t.id DESC LIMIT ? OFFSET ?")
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
