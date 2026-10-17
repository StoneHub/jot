import Foundation
import SQLite3

/// The row insert shared by `append` and a relabel split.
enum TranscriptRows {
    /// Caller holds the lock; one statement serves every row.
    static func insert(_ db: SQLiteConnection, _ transcripts: [Transcript]) throws {
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
}
