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

/// Speaker pass rows, kept in the transcripts database next to the session's text, on a connection of its own.
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
    private let db: SQLiteConnection

    /// Opens after `store`, which created the tables.
    public init(sharing store: TranscriptStore) throws {
        db = try SQLiteConnection(url: store.databaseURL)
    }

    /// Replaces whatever an earlier pass stored for the session. A speaker's duration is the sum of its segments.
    public func replace(sessionID: String, result: SpeakerPassResult) throws {
        guard !sessionID.isEmpty, result.segments.allSatisfy({ !$0.speaker.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              result.speakers.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty && $0.value.allSatisfy(\.isFinite) }) else { throw StoreError.invalid("Invalid speaker pass fields") }
        var durations: [String: Double] = [:]
        for segment in result.segments { durations[segment.speaker, default: 0] += segment.end - segment.start }
        try db.locked {
            try db.transaction {
                for table in ["session_speakers", "session_segments"] {
                    let stmt = try db.prepare("DELETE FROM \(table) WHERE session_id = ?")
                    defer { sqlite3_finalize(stmt) }
                    db.bind(sessionID, to: 1, in: stmt); try db.finish(stmt)
                }
                for (speaker, embedding) in result.speakers.sorted(by: { $0.key < $1.key }) {
                    let stmt = try db.prepare("INSERT INTO session_speakers(session_id,speaker_id,embedding,duration_seconds) VALUES(?,?,?,?)")
                    defer { sqlite3_finalize(stmt) }
                    db.bind(sessionID, to: 1, in: stmt); db.bind(speaker, to: 2, in: stmt)
                    db.bind(Self.blob(embedding), to: 3, in: stmt)
                    sqlite3_bind_double(stmt, 4, durations[speaker] ?? 0)
                    try db.finish(stmt)
                }
                for segment in result.segments {
                    let stmt = try db.prepare("INSERT INTO session_segments(session_id,speaker_id,start_seconds,end_seconds) VALUES(?,?,?,?)")
                    defer { sqlite3_finalize(stmt) }
                    db.bind(sessionID, to: 1, in: stmt); db.bind(segment.speaker, to: 2, in: stmt)
                    sqlite3_bind_double(stmt, 3, segment.start); sqlite3_bind_double(stmt, 4, segment.end)
                    try db.finish(stmt)
                }
            }
        }
    }

    public func speakers(sessionID: String) throws -> [Speaker] {
        try db.locked {
            let stmt = try db.prepare("SELECT speaker_id,embedding,duration_seconds FROM session_speakers WHERE session_id = ? ORDER BY speaker_id")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            var result: [Speaker] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(Speaker(speakerID: db.column(stmt, 0)!, embedding: Self.floats(db.blob(stmt, 1)), durationSeconds: sqlite3_column_double(stmt, 2)))
            }
            return result
        }
    }

    public func segments(sessionID: String) throws -> [Segment] {
        try db.locked {
            let stmt = try db.prepare("SELECT speaker_id,start_seconds,end_seconds FROM session_segments WHERE session_id = ? ORDER BY start_seconds,end_seconds,speaker_id")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt)
            var result: [Segment] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(Segment(speakerID: db.column(stmt, 0)!, start: sqlite3_column_double(stmt, 1), end: sqlite3_column_double(stmt, 2)))
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
}
