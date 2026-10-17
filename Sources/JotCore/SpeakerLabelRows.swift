import Foundation
import SQLite3

/// Per-session speaker names and the speaker each row was given.
/// `TranscriptStore` calls these with its connection; each takes the lock itself.
enum SpeakerLabelRows {
    static func label(_ db: SQLiteConnection, sessionID: String, speakerID: String, name: String) throws {
        guard !sessionID.isEmpty, !speakerID.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw StoreError.invalid("Session, speaker, and a name of at most 200 characters are required") }
        try db.locked {
            let stmt = try db.prepare("INSERT INTO speaker_labels(session_id,speaker_id,name) VALUES(?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET name=excluded.name")
            defer { sqlite3_finalize(stmt) }
            db.bind(sessionID, to: 1, in: stmt); db.bind(speakerID, to: 2, in: stmt); db.bind(name, to: 3, in: stmt)
            try db.finish(stmt)
        }
    }

    static func labels(_ db: SQLiteConnection, sessionID: String) throws -> [String: String] {
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

    static func replace(_ db: SQLiteConnection, sessionID: String, _ labels: [String: String]) throws {
        try db.locked {
            try db.transaction {
                let existing = try db.prepare("SELECT speaker_id FROM speaker_labels WHERE session_id = ?")
                defer { sqlite3_finalize(existing) }
                db.bind(sessionID, to: 1, in: existing)
                var removed: [String] = []
                while true {
                    let status = sqlite3_step(existing)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw db.error() }
                    let speaker = db.column(existing, 0)!
                    if labels[speaker] == nil { removed.append(speaker) }
                }
                for speaker in removed {
                    let delete = try db.prepare("DELETE FROM speaker_labels WHERE session_id = ? AND speaker_id = ?")
                    defer { sqlite3_finalize(delete) }
                    db.bind(sessionID, to: 1, in: delete)
                    db.bind(speaker, to: 2, in: delete)
                    try db.finish(delete)
                }
                for (speakerID, name) in labels {
                    let insert = try db.prepare("INSERT INTO speaker_labels(session_id,speaker_id,name) VALUES(?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET name=excluded.name")
                    defer { sqlite3_finalize(insert) }
                    db.bind(sessionID, to: 1, in: insert); db.bind(speakerID, to: 2, in: insert); db.bind(name, to: 3, in: insert)
                    try db.finish(insert)
                }
            }
        }
    }

    static func speakerIDs(_ db: SQLiteConnection, sessionID: String) throws -> [String: String] {
        try db.locked {
            let stmt = try db.prepare("SELECT id,speaker_id FROM transcripts WHERE session_id = ? AND speaker_id IS NOT NULL")
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
}
