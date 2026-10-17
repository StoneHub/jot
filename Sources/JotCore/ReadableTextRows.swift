import Foundation
import SQLite3

/// Cleaned text kept beside each transcript row. `TranscriptStore` calls these with its connection; a relabel split reuses `insert` inside its own transaction.
enum ReadableTextRows {
    static func texts(_ db: SQLiteConnection, sessionID: String) throws -> [String: String] {
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

    /// Caller holds the lock and the transaction.
    static func insert(_ db: SQLiteConnection, _ texts: [(transcriptID: String, text: String)]) throws {
        let stmt = try db.prepare("INSERT INTO transcript_readable(transcript_id,text) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        for readable in texts {
            sqlite3_reset(stmt)
            db.bind(readable.transcriptID, to: 1, in: stmt)
            db.bind(readable.text, to: 2, in: stmt)
            try db.finish(stmt)
        }
    }

    static func setPhrase(_ db: SQLiteConnection, _ texts: [String], for sources: [Transcript]) throws -> Bool {
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
}
