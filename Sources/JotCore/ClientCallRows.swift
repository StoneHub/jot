import Foundation
import SQLCipher

/// Socket calls counted per local day, program and method, like usage counters: deleting history leaves them, and
/// rows older than `retainedDays` go on write. `TranscriptStore` calls these with its connection.
enum ClientCallRows {
    static let retainedDays = ClientCallSummary.retainedDays
    static let schema = "CREATE TABLE IF NOT EXISTS client_calls (day TEXT NOT NULL CHECK(length(day) = 10), path TEXT NOT NULL, method TEXT NOT NULL CHECK(length(method) <= 64), count INTEGER NOT NULL CHECK(count >= 1), last_at REAL NOT NULL, PRIMARY KEY(day, path, method));"

    static func record(_ db: SQLiteConnection, _ call: ClientCall, at date: Date, calendar: Calendar) throws {
        guard date.timeIntervalSince1970.isFinite,
              let oldest = calendar.date(byAdding: .day, value: -retainedDays, to: calendar.startOfDay(for: date)) else {
            throw StoreError.invalid("Client calls need a finite date")
        }
        let path = call.executablePath.flatMap { $0.isEmpty ? nil : $0 } ?? ClientCallSummary.unknownPath
        try db.locked {
            try db.transaction {
                let stmt = try db.prepare("INSERT INTO client_calls(day,path,method,count,last_at) VALUES(?,?,?,1,?) ON CONFLICT(day,path,method) DO UPDATE SET count=count+1, last_at=excluded.last_at")
                defer { sqlite3_finalize(stmt) }
                db.bind(UsageCounterRows.day(date, calendar: calendar), to: 1, in: stmt)
                db.bind(String(path.prefix(1024)), to: 2, in: stmt)
                db.bind(String(call.method.prefix(64)), to: 3, in: stmt)
                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                try db.finish(stmt)
                let prune = try db.prepare("DELETE FROM client_calls WHERE day < ?")
                defer { sqlite3_finalize(prune) }
                db.bind(UsageCounterRows.day(oldest, calendar: calendar), to: 1, in: prune)
                try db.finish(prune)
            }
        }
    }

    /// Programs and methods over the last `days` local days including today, most calls first.
    static func summary(_ db: SQLiteConnection, days: Int, now: Date, calendar: Calendar) throws -> [ClientCallSummary] {
        let span = max(1, min(retainedDays, days))
        guard let first = calendar.date(byAdding: .day, value: 1 - span, to: calendar.startOfDay(for: now)) else {
            throw StoreError.invalid("Client calls need a finite date")
        }
        return try db.locked {
            let stmt = try db.prepare("SELECT path, method, SUM(count), MIN(day), MAX(last_at) FROM client_calls WHERE day >= ? GROUP BY path, method ORDER BY SUM(count) DESC, path, method")
            defer { sqlite3_finalize(stmt) }
            db.bind(UsageCounterRows.day(first, calendar: calendar), to: 1, in: stmt)
            var result: [ClientCallSummary] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(ClientCallSummary(path: db.column(stmt, 0)!, method: db.column(stmt, 1)!, count: Int(sqlite3_column_int64(stmt, 2)),
                                                firstDay: db.column(stmt, 3)!, lastAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))))
            }
            return result
        }
    }
}
