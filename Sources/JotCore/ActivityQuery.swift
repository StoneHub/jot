import Foundation
import SQLite3

/// The Activity page's read: word counts, speech time, sessions and verified deliveries per day, for 7 or 30 days.
/// `TranscriptStore.activity` calls it with the store's connection; it reads and changes nothing else.
enum ActivityQuery {
    static func report(_ db: SQLiteConnection, days: Int, now: Date, calendar: Calendar) throws -> ActivityReport {
        guard [7, 30].contains(days), now.timeIntervalSince1970.isFinite else {
            throw StoreError.invalid("Activity requires 7 or 30 days and a finite date")
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: today) else {
            throw StoreError.invalid("Could not determine activity calendar window")
        }
        let dates = try (0..<days).map { offset -> Date in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw StoreError.invalid("Could not determine activity calendar day")
            }
            return date
        }
        let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, $0.offset) })
        return try db.locked {
            var dictation = ActivityAccumulator(), ambient = ActivityAccumulator()
            var dailyDictation = Array(repeating: ActivityAccumulator(), count: days)
            var dailyAmbient = Array(repeating: ActivityAccumulator(), count: days)
            var deliveries = Array(repeating: 0, count: days)
            let rows = try db.prepare("""
                SELECT t.session_id,(t.started_at+t.start_seconds),(t.started_at+t.end_seconds),COALESCE(r.text,t.text),t.mode
                FROM transcripts t LEFT JOIN transcript_readable r ON r.transcript_id=t.id
                WHERE (t.started_at+t.start_seconds) >= ?1 AND (t.started_at+t.start_seconds) <= ?2
                """)
            defer { sqlite3_finalize(rows) }
            sqlite3_bind_double(rows, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(rows, 2, now.timeIntervalSince1970)
            while true {
                let status = sqlite3_step(rows)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let began = sqlite3_column_double(rows, 1)
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: began))
                guard let index = indices[day] else { continue }
                let words = (db.column(rows, 3) ?? "").split(whereSeparator: \.isWhitespace).reduce(0) { count, token in
                    count + (token.contains(where: { $0.isLetter || $0.isNumber }) ? 1 : 0)
                }
                let ended = sqlite3_column_double(rows, 2)
                let completeTiming = ended.isFinite && ended <= now.timeIntervalSince1970
                let duration = max(0, min(ended, now.timeIntervalSince1970) - began)
                let session = db.column(rows, 0)!
                if db.column(rows, 4) == "dictation" {
                    dictation.add(words: words, duration: duration, session: session, day: day, completeTiming: completeTiming)
                    dailyDictation[index].add(words: words, duration: duration, session: session, day: day, completeTiming: completeTiming)
                } else {
                    ambient.add(words: words, duration: duration, session: session, day: day, completeTiming: completeTiming)
                    dailyAmbient[index].add(words: words, duration: duration, session: session, day: day, completeTiming: completeTiming)
                }
            }
            // State + updated_at uses the existing recovery index. A retry retains
            // one attempt, with its latest successful verification's date.
            let attempts = try db.prepare("SELECT updated_at FROM dictation_attempts WHERE state='delivered' AND updated_at >= ?1 AND updated_at <= ?2")
            defer { sqlite3_finalize(attempts) }
            sqlite3_bind_double(attempts, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(attempts, 2, now.timeIntervalSince1970)
            while true {
                let status = sqlite3_step(attempts)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(attempts, 0)))
                if let index = indices[day] { deliveries[index] += 1 }
            }
            return ActivityReport(generatedAt: now, windowStart: start, windowEnd: now, days: days,
                timeZoneIdentifier: calendar.timeZone.identifier, dictation: dictation.summary, ambient: ambient.summary,
                verifiedDictationDeliveries: deliveries.reduce(0, +), daily: dates.enumerated().map { index, date in
                    ActivityDay(date: date, dictation: dailyDictation[index].summary, ambient: dailyAmbient[index].summary,
                                verifiedDictationDeliveries: deliveries[index])
                })
        }
    }

    private struct ActivityAccumulator {
        var words = 0, timedWords = 0, segments = 0
        var duration: Double = 0
        var completeTiming = true
        var sessions: Set<String> = []
        var days: Set<Date> = []

        mutating func add(words: Int, duration: Double, session: String, day: Date, completeTiming: Bool) {
            self.words += words; segments += 1
            if duration > 0 { timedWords += words; self.duration += duration }
            self.completeTiming = self.completeTiming && completeTiming
            sessions.insert(session); days.insert(day)
        }

        var summary: ActivityModeSummary {
            ActivityModeSummary(wordCount: words, timedWordCount: timedWords, segmentCount: segments,
                                sessionCount: sessions.count, speechWindowSeconds: duration, activeDays: days.count,
                                hasCompleteTiming: completeTiming)
        }
    }
}
