import Foundation
import SQLite3

/// Text-free usage counts, one row per local day and counter name. Deleting history leaves them: they count what
/// happened, not what is retained. Rows older than `retainedDays` are pruned on write.
/// `TranscriptStore` calls these with its connection.
enum UsageCounterRows {
    static let retainedDays = 400

    /// The local calendar day a count belongs to, as `yyyy-MM-dd`.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds one to each counter, in one transaction. A counter listed twice counts twice.
    static func add(_ db: SQLiteConnection, _ counters: [UsageCounter], at date: Date, calendar: Calendar) throws {
        guard !counters.isEmpty else { return }
        guard date.timeIntervalSince1970.isFinite,
              let oldest = calendar.date(byAdding: .day, value: -retainedDays, to: calendar.startOfDay(for: date)) else {
            throw StoreError.invalid("Usage counters need a finite date")
        }
        let today = day(date, calendar: calendar)
        try db.locked {
            try db.transaction {
                let stmt = try db.prepare("INSERT INTO usage_counters(day,name,count) VALUES(?,?,1) ON CONFLICT(day,name) DO UPDATE SET count=count+1")
                defer { sqlite3_finalize(stmt) }
                for counter in counters {
                    sqlite3_reset(stmt)
                    db.bind(today, to: 1, in: stmt); db.bind(counter.name, to: 2, in: stmt)
                    try db.finish(stmt)
                }
                let prune = try db.prepare("DELETE FROM usage_counters WHERE day < ?")
                defer { sqlite3_finalize(prune) }
                db.bind(day(oldest, calendar: calendar), to: 1, in: prune)
                try db.finish(prune)
            }
        }
    }

    /// Counts by day key and name for the given days. Caller holds the lock.
    static func counts(_ db: SQLiteConnection, days: [String]) throws -> [String: [String: Int]] {
        guard let first = days.min(), let last = days.max() else { return [:] }
        let stmt = try db.prepare("SELECT day,name,count FROM usage_counters WHERE day >= ? AND day <= ?")
        defer { sqlite3_finalize(stmt) }
        db.bind(first, to: 1, in: stmt); db.bind(last, to: 2, in: stmt)
        var result: [String: [String: Int]] = [:]
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw db.error() }
            result[db.column(stmt, 0)!, default: [:]][db.column(stmt, 1)!] = Int(sqlite3_column_int64(stmt, 2))
        }
        return result
    }
}
