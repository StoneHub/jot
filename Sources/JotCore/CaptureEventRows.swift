import Foundation
import SQLite3

/// Capture lifecycle events, kept per session. They carry metadata only, never transcript text or audio.
/// `TranscriptStore` calls these with its connection and passes an already clamped limit.
enum CaptureEventRows {
    static func append(_ db: SQLiteConnection, _ event: CaptureEvent) throws {
        guard !event.id.isEmpty, !event.sessionID.isEmpty, !event.kind.isEmpty,
              event.kind.utf8.count <= 100, event.detail.utf8.count <= 2000,
              event.timestamp.timeIntervalSince1970.isFinite,
              event.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw StoreError.invalid("Invalid capture event fields") }
        try db.locked {
            let stmt = try db.prepare("INSERT INTO capture_events(id,session_id,timestamp,kind,detail,duration_seconds) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            db.bind(event.id, to: 1, in: stmt); db.bind(event.sessionID, to: 2, in: stmt)
            sqlite3_bind_double(stmt, 3, event.timestamp.timeIntervalSince1970)
            db.bind(event.kind, to: 4, in: stmt); db.bind(event.detail, to: 5, in: stmt)
            if let duration = event.durationSeconds { sqlite3_bind_double(stmt, 6, duration) } else { sqlite3_bind_null(stmt, 6) }
            try db.finish(stmt)
        }
    }

    static func events(_ db: SQLiteConnection, sessionID: String?, limit: Int, offset: Int) throws -> [CaptureEvent] {
        try db.locked {
            let clause = sessionID == nil ? "" : "WHERE session_id = ?"
            let stmt = try db.prepare("SELECT id,session_id,timestamp,kind,detail,duration_seconds FROM capture_events \(clause) ORDER BY timestamp DESC,id DESC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let sessionID { db.bind(sessionID, to: index, in: stmt); index += 1 }
            sqlite3_bind_int(stmt, index, Int32(limit))
            sqlite3_bind_int64(stmt, index + 1, Int64(max(0, offset)))
            var result: [CaptureEvent] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(CaptureEvent(id: db.column(stmt, 0)!, sessionID: db.column(stmt, 1)!,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    kind: db.column(stmt, 3)!, detail: db.column(stmt, 4)!,
                    durationSeconds: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)))
            }
            return result
        }
    }
}
