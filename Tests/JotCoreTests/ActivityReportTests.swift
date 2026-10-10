import XCTest
@testable import JotCore

final class ActivityReportTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-activity-" + UUID().uuidString)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute)))
    }

    @discardableResult
    private func append(_ store: TranscriptStore, _ id: String, at: Date, seconds: Double = 60,
                        text: String = "one two", mode: String = "dictation", session: String = "same-session") throws -> Transcript {
        let row = Transcript(id: id, sessionID: session, startedAt: at, startSeconds: 0,
                             endSeconds: seconds, text: text, mode: mode)
        try store.append(row)
        return row
    }

    func testEmptyZeroFilledLocalDaysSurviveDSTAndJSONHasExplicitNullRate() throws {
        let store = try TranscriptStore(directory: directory), now = try date(9, hour: 12)
        let report = try store.activity(now: now, calendar: calendar)
        XCTAssertEqual(report.windowStart, try date(3))
        XCTAssertEqual(report.windowEnd, now)
        XCTAssertEqual(report.daily.count, 7)
        XCTAssertEqual(report.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(report.daily[6].date.timeIntervalSince(report.daily[5].date), 23 * 3600)
        XCTAssertTrue(report.daily.allSatisfy { $0.dictation.wordCount == 0 && $0.ambient.wordCount == 0 })
        XCTAssertEqual(report.dictation.activeDays, 0)
        XCTAssertNil(report.dictation.wordsPerMinute)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
        let summary = try XCTUnwrap(json["dictation"] as? [String: Any])
        XCTAssertTrue(summary["wordsPerMinute"] is NSNull)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ActivityReport.self, from: encoder.encode(report)), report)
        XCTAssertEqual(try store.activity(days: 30, now: now, calendar: calendar).daily.count, 30)
    }

    func testCleanedWordsModeSeparationDistinctSessionsAndZeroDurationRate() throws {
        let store = try TranscriptStore(directory: directory), now = try date(9, hour: 12)
        let first = try append(store, "first", at: date(8, hour: 9), text: "raw text was longer here")
        XCTAssertTrue(try store.setReadablePhrase(["Cleaned words."], for: [first]))
        try append(store, "second", at: date(9, hour: 9), text: "don't re-enter 42 … 😀", session: "same-session")
        try append(store, "zero", at: date(9, hour: 10), seconds: 0, text: "zero duration words", session: "second-session")
        try append(store, "ambient", at: date(8, hour: 9), seconds: 120, text: "other people's conversation", mode: "ambient")
        let report = try store.activity(now: now, calendar: calendar)
        XCTAssertEqual(report.dictation.wordCount, 8)
        XCTAssertEqual(report.dictation.timedWordCount, 5)
        XCTAssertEqual(report.dictation.segmentCount, 3)
        XCTAssertEqual(report.dictation.sessionCount, 2, "A session repeated on two days counts once in the total")
        XCTAssertEqual(report.dictation.activeDays, 2)
        XCTAssertEqual(report.dictation.speechWindowSeconds, 120)
        XCTAssertEqual(try XCTUnwrap(report.dictation.wordsPerMinute), 2.5)
        XCTAssertEqual(report.ambient.wordCount, 3)
        XCTAssertEqual(report.ambient.segmentCount, 1)
        XCTAssertEqual(report.ambient.speechWindowSeconds, 120)
        XCTAssertEqual(report.daily[5].dictation.wordCount, 2)
        XCTAssertEqual(report.daily[6].dictation.wordCount, 6)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for privateValue in ["Cleaned words", "raw text was longer", "other people's conversation", "same-session", "second-session"] {
            XCTAssertFalse(encoded.contains(privateValue), "Aggregate payload must not include \(privateValue)")
        }
        try store.deleteTranscripts(ids: ["first"])
        XCTAssertEqual(try store.activity(now: now, calendar: calendar).dictation.wordCount, 6)
    }

    func testAbsoluteStartBoundsMidnightAttributionAndFutureDurationSuppressesRate() throws {
        let store = try TranscriptStore(directory: directory), now = try date(9, hour: 12), start = try date(3)
        try append(store, "too-old", at: start.addingTimeInterval(-1), seconds: 120)
        try append(store, "first-in-window", at: start)
        try append(store, "cross-midnight", at: date(8, hour: 23, minute: 59), seconds: 120)
        // Session origin is outside the window, but this row's absolute start is inside it.
        try store.append(Transcript(id: "offset", sessionID: "offset-session", startedAt: start.addingTimeInterval(-3600),
                                    startSeconds: 7200, endSeconds: 7260, text: "offset", mode: "dictation"))
        try append(store, "partial", at: now.addingTimeInterval(-30), seconds: 60)
        try append(store, "at-now", at: now, seconds: 0, text: "now")
        try append(store, "future", at: now.addingTimeInterval(1))
        let report = try store.activity(now: now, calendar: calendar)
        XCTAssertEqual(report.dictation.segmentCount, 5)
        XCTAssertEqual(report.dictation.wordCount, 8)
        XCTAssertEqual(report.dictation.speechWindowSeconds, 270)
        XCTAssertEqual(report.daily[5].dictation.speechWindowSeconds, 120, "A cross-midnight row belongs to its start day")
        XCTAssertEqual(report.daily[6].dictation.speechWindowSeconds, 30)
        XCTAssertFalse(report.dictation.hasCompleteTiming)
        XCTAssertNil(report.dictation.wordsPerMinute, "Full saved text cannot be divided by partial window time")
        XCTAssertEqual(report.daily[0].dictation.wordsPerMinute, 1.5)
    }

    func testVerifiedInsertionsCountLatestRetainedDeliveryStateRatherThanRowsOrHolds() throws {
        let store = try TranscriptStore(directory: directory), now = try date(9, hour: 12)
        let began = try date(2), updated = try date(8, hour: 10)
        for state in [DictationAttempt.State.delivered, .deliveryUnverified, .deliveryFailed, .ready, .recognizing, .discarded] {
            try store.saveDictationAttempt(DictationAttempt(id: state.rawValue, sessionID: "private-session", startedAt: began,
                endedAt: began.addingTimeInterval(10), text: "private attempt text", state: state, updatedAt: updated))
        }
        var report = try store.activity(now: now, calendar: calendar)
        XCTAssertEqual(report.verifiedDictationDeliveries, 1)
        XCTAssertEqual(report.daily[5].verifiedDictationDeliveries, 1)
        XCTAssertEqual(report.dictation.segmentCount, 0, "A delivery attempt is not a transcript row")
        // Retrying updates the same record, so it moves bucket without double counting.
        try store.saveDictationAttempt(DictationAttempt(id: "delivered", sessionID: "private-session", startedAt: began,
            endedAt: began.addingTimeInterval(10), state: .delivered, updatedAt: now))
        report = try store.activity(now: now, calendar: calendar)
        XCTAssertEqual(report.verifiedDictationDeliveries, 1)
        XCTAssertEqual(report.daily[5].verifiedDictationDeliveries, 0)
        XCTAssertEqual(report.daily[6].verifiedDictationDeliveries, 1)
        try store.deleteDictationAttempt(id: "delivered")
        XCTAssertEqual(try store.activity(now: now, calendar: calendar).verifiedDictationDeliveries, 0)
    }

    func testInvalidWindowsAndSocketArgumentsAreRejected() throws {
        let store = try TranscriptStore(directory: directory), now = try date(9)
        for days in [-1, 0, 1, 8, 31, Int.max] { XCTAssertThrowsError(try store.activity(days: days, now: now, calendar: calendar)) }
        XCTAssertThrowsError(try store.activity(now: Date(timeIntervalSince1970: .infinity), calendar: calendar))
        XCTAssertEqual(try ActivityRequest.days(arguments: [:]), 7)
        XCTAssertEqual(try ActivityRequest.days(arguments: ["days": 30]), 30)
        let invalid: [Any] = [true, false, 7.5, 8, "7", NSNull()]
        for value in invalid {
            XCTAssertThrowsError(try ActivityRequest.days(arguments: ["days": value]))
        }
        XCTAssertThrowsError(try ActivityRequest.days(arguments: ["limit": 7]))
    }
}
