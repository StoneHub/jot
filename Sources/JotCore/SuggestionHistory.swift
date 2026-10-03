import Foundation
import SQLite3

/// Owns one small table in the existing transcript database. Actor isolation keeps writes off the UI actor.
public actor SuggestionHistory {
    public static let maximumRows = 200
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private let db: SQLiteConnection

    public init(sharing store: TranscriptStore) throws {
        db = try SQLiteConnection(url: store.databaseURL)
        try db.locked {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS suggestion_interactions (
                    id TEXT PRIMARY KEY, started_at REAL NOT NULL, revision INTEGER NOT NULL,
                    complete INTEGER NOT NULL, interrupted INTEGER NOT NULL DEFAULT 0,
                    payload BLOB NOT NULL CHECK(length(payload) <= 4096));
                CREATE INDEX IF NOT EXISTS suggestion_interactions_time
                    ON suggestion_interactions(started_at DESC);
                """)
            // Any unfinished card from the previous process can no longer be accepted.
            try db.execute("UPDATE suggestion_interactions SET interrupted=1 WHERE complete=0")
            try Self.prune(db, now: Date())
        }
    }

    public func save(_ entry: SuggestionHistoryEntry, now: Date = Date()) throws {
        try entry.validate()
        let payload = try JSONEncoder().encode(entry)
        guard payload.count <= 4096 else { throw StoreError.invalid("Suggestion diagnostics exceed 4 KiB") }
        try db.locked {
            try db.transaction {
                let stmt = try db.prepare("""
                    INSERT INTO suggestion_interactions(id,started_at,revision,complete,interrupted,payload)
                    VALUES(?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET
                    started_at=excluded.started_at, revision=excluded.revision,
                    complete=excluded.complete, payload=excluded.payload
                    WHERE excluded.revision > suggestion_interactions.revision
                    """)
                defer { sqlite3_finalize(stmt) }
                db.bind(entry.id.uuidString, to: 1, in: stmt)
                sqlite3_bind_double(stmt, 2, entry.startedAt.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, Int64(entry.revision))
                sqlite3_bind_int(stmt, 4, entry.complete ? 1 : 0)
                db.bind(payload, to: 5, in: stmt)
                try db.finish(stmt)
                try Self.prune(db, now: now)
            }
        }
    }

    public func recent(limit: Int = 20, now: Date = Date()) throws -> [SavedSuggestionInteraction] {
        guard (1...Self.maximumRows).contains(limit) else { throw StoreError.invalid("Suggestion limit must be 1...200") }
        return try db.locked {
            try Self.prune(db, now: now)
            let stmt = try db.prepare("SELECT payload,interrupted FROM suggestion_interactions ORDER BY started_at DESC,id DESC LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [SavedSuggestionInteraction] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let entry = try JSONDecoder().decode(SuggestionHistoryEntry.self, from: db.blob(stmt, 0))
                rows.append(SavedSuggestionInteraction(entry: entry, interrupted: sqlite3_column_int(stmt, 1) != 0))
            }
            return rows
        }
    }

    private static func prune(_ db: SQLiteConnection, now: Date) throws {
        try db.execute("DELETE FROM suggestion_interactions WHERE started_at < \(now.addingTimeInterval(-maximumAge).timeIntervalSince1970)")
        try db.execute("""
            DELETE FROM suggestion_interactions WHERE id NOT IN
                (SELECT id FROM suggestion_interactions ORDER BY started_at DESC,id DESC LIMIT \(maximumRows))
            """)
    }
}
