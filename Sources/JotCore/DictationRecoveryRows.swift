import Foundation
import SQLite3

/// Dictation attempts saved for force-quit recovery, and the recognized speech recovery offers in their place.
/// `TranscriptStore` calls these with its connection; no raw audio is read or written.
enum DictationRecoveryRows {
    static func save(_ db: SQLiteConnection, _ attempt: DictationAttempt) throws {
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

    static func latestRecoverable(_ db: SQLiteConnection) throws -> DictationAttempt? {
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

    static func finalizeInterrupted(_ db: SQLiteConnection, converting: (String) -> String) throws {
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

    static func recoveryText(_ db: SQLiteConnection, from lowerBound: Date, through upperBound: Date) throws -> String {
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
}
