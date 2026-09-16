import Foundation
import SQLite3

/// What the offline speaker pass found in one session: who spoke when, and one voice embedding per speaker.
public struct SpeakerPassResult: Sendable {
    public var segments: [(speaker: String, start: Double, end: Double)]
    public var speakers: [String: [Float]]
    public var durationSeconds: Double
    public var processingSeconds: Double
    public init(segments: [(speaker: String, start: Double, end: Double)], speakers: [String: [Float]], durationSeconds: Double, processingSeconds: Double) {
        self.segments = segments; self.speakers = speakers; self.durationSeconds = durationSeconds; self.processingSeconds = processingSeconds
    }
}

/// Speaker pass rows, kept in the transcripts database next to the session's text. This is a second connection to that file: TranscriptStore keeps its SQL helpers private, and WAL mode lets both connections share it.
public final class SpeakerPassStore: @unchecked Sendable {
    public struct Speaker: Sendable, Equatable {
        public let speakerID: String
        public let embedding: [Float]
        public let durationSeconds: Double
    }
    public struct Segment: Sendable, Equatable {
        public let speakerID: String
        public let start: Double
        public let end: Double
    }
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL = JotPaths.directory) throws {
        try preparePrivateDirectory(directory)
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open transcript database"
            if let db { sqlite3_close(db) }; db = nil
            throw StoreError.database(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            sqlite3_busy_timeout(db, 5_000)
            // The embedding is 256 Float32 little-endian, the size WeSpeaker produces; duration is that speaker's total speech in the session.
            try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS session_speakers (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, embedding BLOB NOT NULL, duration_seconds REAL NOT NULL CHECK(duration_seconds >= 0), PRIMARY KEY(session_id, speaker_id)); CREATE TABLE IF NOT EXISTS session_segments (session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, start_seconds REAL NOT NULL CHECK(start_seconds >= 0), end_seconds REAL NOT NULL CHECK(end_seconds >= start_seconds)); CREATE INDEX IF NOT EXISTS session_segment_time ON session_segments(session_id, start_seconds);")
        } catch {
            sqlite3_close(db); db = nil; throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Replaces whatever an earlier pass stored for the session. A speaker's duration is the sum of its segments.
    public func replace(sessionID: String, result: SpeakerPassResult) throws {
        guard !sessionID.isEmpty, result.segments.allSatisfy({ !$0.speaker.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              result.speakers.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty && $0.value.allSatisfy(\.isFinite) }) else { throw StoreError.invalid("Invalid speaker pass fields") }
        var durations: [String: Double] = [:]
        for segment in result.segments { durations[segment.speaker, default: 0] += segment.end - segment.start }
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                for table in ["session_speakers", "session_segments"] {
                    let stmt = try prepare("DELETE FROM \(table) WHERE session_id = ?")
                    defer { sqlite3_finalize(stmt) }
                    bind(sessionID, to: 1, in: stmt); try finish(stmt)
                }
                for (speaker, embedding) in result.speakers.sorted(by: { $0.key < $1.key }) {
                    let stmt = try prepare("INSERT INTO session_speakers(session_id,speaker_id,embedding,duration_seconds) VALUES(?,?,?,?)")
                    defer { sqlite3_finalize(stmt) }
                    bind(sessionID, to: 1, in: stmt); bind(speaker, to: 2, in: stmt)
                    let blob = Self.blob(embedding)
                    blob.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), transient) }
                    sqlite3_bind_double(stmt, 4, durations[speaker] ?? 0)
                    try finish(stmt)
                }
                for segment in result.segments {
                    let stmt = try prepare("INSERT INTO session_segments(session_id,speaker_id,start_seconds,end_seconds) VALUES(?,?,?,?)")
                    defer { sqlite3_finalize(stmt) }
                    bind(sessionID, to: 1, in: stmt); bind(segment.speaker, to: 2, in: stmt)
                    sqlite3_bind_double(stmt, 3, segment.start); sqlite3_bind_double(stmt, 4, segment.end)
                    try finish(stmt)
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    public func speakers(sessionID: String) throws -> [Speaker] {
        try locked {
            let stmt = try prepare("SELECT speaker_id,embedding,duration_seconds FROM session_speakers WHERE session_id = ? ORDER BY speaker_id")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt)
            var result: [Speaker] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                let bytes = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 1))) } ?? Data()
                result.append(Speaker(speakerID: column(stmt, 0)!, embedding: Self.floats(bytes), durationSeconds: sqlite3_column_double(stmt, 2)))
            }
            return result
        }
    }

    public func segments(sessionID: String) throws -> [Segment] {
        try locked {
            let stmt = try prepare("SELECT speaker_id,start_seconds,end_seconds FROM session_segments WHERE session_id = ? ORDER BY start_seconds,end_seconds,speaker_id")
            defer { sqlite3_finalize(stmt) }
            bind(sessionID, to: 1, in: stmt)
            var result: [Segment] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                result.append(Segment(speakerID: column(stmt, 0)!, start: sqlite3_column_double(stmt, 1), end: sqlite3_column_double(stmt, 2)))
            }
            return result
        }
    }

    static func blob(_ embedding: [Float]) -> Data {
        var bytes = Data(capacity: embedding.count * 4)
        for value in embedding { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        return bytes
    }

    static func floats(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - data.count % 4, by: 4).map { offset in
            Float(bitPattern: UInt32(littleEndian: data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    private func error() -> StoreError { .database(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func finish(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() } }
    private func bind(_ value: String, to index: Int32, in stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, value, -1, transient) }
    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: bytes)
    }
}
