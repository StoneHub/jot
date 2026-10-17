import Foundation
import SQLite3

/// Writes a relabel plan for one finished session: kept rows take their new speaker, split rows are replaced by one row per speaker.
/// `TranscriptStore.relabelSession` calls `run` with its connection, without holding the lock; each batch takes it.
enum SessionRelabel {
    static func run(_ db: SQLiteConnection, sessionID id: String, speakers: ([StoredWord]) -> [String?]) throws -> Bool {
        let words = try StoredWordRows.words(db, sessionID: id)
        if words.isEmpty { return false }
        let readable = try ReadableTextRows.texts(db, sessionID: id)
        let plan = try RowRelabel(words: words, speakers: speakers(words), readable: readable)
        try inBatches(db, plan.kept) { try relabel(db, $0, sessionID: id) }
        try inBatches(db, plan.splits) { try split(db, $0, sessionID: id) }
        return true
    }

    /// How long a relabel batch may hold the lock before it commits.
    private static let relabelBatchWork = Duration.milliseconds(5)

    /// Writes a relabel plan a batch at a time. Each batch is one transaction that commits once about 5 ms of work is done. NSLock is not fair: a batch that takes the lock straight after the one before can keep a waiting reader, such as the main thread, out for several batches, so a millisecond's pause between batches lets it in.
    private static func inBatches<Row>(_ db: SQLiteConnection, _ rows: [Row], write: (Row) throws -> Void) throws {
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

    /// A kept row takes its new speaker. A row that is gone, deleted with its session, changes nothing. Caller holds the lock and the transaction.
    private static func relabel(_ db: SQLiteConnection, _ row: (rowID: String, speaker: String?), sessionID: String) throws {
        let update = try db.prepare("UPDATE transcripts SET speaker_id=? WHERE id=? AND session_id=? AND mode='ambient'")
        defer { sqlite3_finalize(update) }
        db.bind(row.speaker, to: 1, in: update)
        db.bind(row.rowID, to: 2, in: update)
        db.bind(sessionID, to: 3, in: update)
        try db.finish(update)
    }

    /// A split row is deleted, which takes its words and cleaned text with it, and its pieces are inserted in its place. A row that is gone, deleted with its session, gets no pieces. Caller holds the lock and the transaction.
    private static func split(_ db: SQLiteConnection, _ split: RowRelabel.Split, sessionID: String) throws {
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
            try StoredWordRows.validate(pieceWords)
            rows.append(row)
            words.append(contentsOf: pieceWords)
            if let text = piece.readable { readable.append((transcriptID: row.id, text: text)) }
        }
        try TranscriptRows.insert(db, rows)
        try StoredWordRows.insert(db, words)
        try ReadableTextRows.insert(db, readable)
    }
}
