import Foundation
import SQLite3

/// Word timing and probabilities for each transcript row, the input to regrouping and the speaker pass.
/// `TranscriptStore` calls these with its connection; a relabel split reuses `validate` and `insert` inside its own transaction.
enum StoredWordRows {
    static func append(_ db: SQLiteConnection, _ words: [StoredWord]) throws {
        guard words.count <= 20_000 else { throw StoreError.invalid("Too many words in one batch") }
        try validate(words)
        try db.locked { try db.transaction { try insert(db, words) } }
    }

    static func words(_ db: SQLiteConnection, sessionID: String) throws -> [StoredWord] {
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

    static func validate(_ words: [StoredWord]) throws {
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
    static func insert(_ db: SQLiteConnection, _ words: [StoredWord]) throws {
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
}
