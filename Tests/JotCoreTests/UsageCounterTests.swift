import XCTest
@testable import JotCore

final class UsageCounterTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-usage-" + UUID().uuidString)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func date(_ day: Int, month: Int = 3, hour: Int = 12) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    func testCountsLandOnTheirLocalDayAndSumOverTheWindow() throws {
        let store = try TranscriptStore(directory: directory)
        try store.countUsage([.dictation(.completed), .insertion(.accessibility)], at: date(8, hour: 23), calendar: calendar)
        try store.countUsage([.dictation(.completed), .dictation(.completed)], at: date(9, hour: 0), calendar: calendar)
        try store.countUsage([.dictation(.failed)], at: date(1), calendar: calendar)
        let report = try store.activity(now: date(9), calendar: calendar)
        XCTAssertEqual(report.daily[5].counters, ["dictation.completed": 1, "insertion.accessibility": 1], "23:00 local stays on the 8th")
        XCTAssertEqual(report.daily[6].counters, ["dictation.completed": 2], "A counter listed twice counts twice")
        XCTAssertEqual(report.counters, ["dictation.completed": 3, "insertion.accessibility": 1], "The 1st is outside the 7-day window")
        XCTAssertEqual(try store.activity(days: 30, now: date(9), calendar: calendar).counters["dictation.failed"], 1)
    }

    func testDeletingHistoryLeavesCounters() throws {
        let store = try TranscriptStore(directory: directory)
        let row = Transcript(id: "d1", sessionID: "s1", startedAt: try date(9, hour: 9), startSeconds: 0, endSeconds: 2, text: "hello there", mode: "dictation")
        try store.append(row)
        try store.countUsage([.dictation(.completed)], at: date(9, hour: 9), calendar: calendar)
        try store.deleteTranscripts(ids: ["d1"])
        try store.deleteSession(id: "s1")
        try store.clearHistory()
        let report = try store.activity(now: date(9), calendar: calendar)
        XCTAssertEqual(report.dictation.wordCount, 0)
        XCTAssertEqual(report.counters, ["dictation.completed": 1])
    }

    func testResetClearsCountersAndKeepsHistory() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(Transcript(id: "d1", sessionID: "s1", startedAt: try date(9, hour: 9), startSeconds: 0, endSeconds: 2, text: "hello there", mode: "dictation"))
        try store.countUsage([.dictation(.completed)], at: date(9, hour: 9), calendar: calendar)
        try store.resetUsage()
        let report = try store.activity(now: date(9), calendar: calendar)
        XCTAssertEqual(report.counters, [:])
        XCTAssertEqual(report.dictation.wordCount, 2)
    }

    func testOldDaysArePrunedOnWrite() throws {
        let store = try TranscriptStore(directory: directory)
        try store.countUsage([.suggestionRequested], at: date(1, month: 1), calendar: calendar)
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: UsageCounterRows.retainedDays + 1, to: date(1, month: 1)))
        try store.countUsage([.suggestionRequested], at: later, calendar: calendar)
        let counts = try SQLiteConnection(url: directory.appendingPathComponent("transcripts.sqlite3"))
        defer { counts.close() }
        XCTAssertEqual(try counts.integer("SELECT COUNT(*) FROM usage_counters"), 1)
        XCTAssertEqual(try counts.integer("SELECT SUM(count) FROM usage_counters"), 1)
    }

    func testNamesComeOnlyFromFixedCodes() {
        let names = UsageCounter.allCases.map(\.name)
        XCTAssertEqual(names.count, 49)
        XCTAssertEqual(Set(names).count, names.count, "Every counter has its own name")
        for name in names {
            XCTAssertNotNil(name.range(of: "^[a-z][A-Za-z]*(\\.[A-Za-z]+)+$", options: .regularExpression), name)
            XCTAssertLessThanOrEqual(name.utf8.count, 64, name)
        }
    }

    /// The Worker refuses names it does not list, so a counter added here must be added there too.
    func testAnalyticsWorkerAllowsExactlyTheseNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("services/analytics/src/counters.js"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "^\\s+\"([A-Za-z.]+)\",$", options: .anchorsMatchLines)
        let listed = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertEqual(listed, UsageCounter.allCases.map(\.name))
    }

    func testInsertionPathsMapToCounters() {
        XCTAssertEqual(UsageCounter.delivery(verified: true, path: "accessibility"), .insertion(.accessibility))
        XCTAssertEqual(UsageCounter.delivery(verified: true, path: "unicode_hid"), .insertion(.unicode))
        XCTAssertEqual(UsageCounter.delivery(verified: true, path: "clipboard_hid"), .insertion(.clipboard))
        XCTAssertEqual(UsageCounter.delivery(verified: false, path: "clipboard_hid"), .insertion(.unverified))
        XCTAssertEqual(UsageCounter.delivery(verified: false, path: "none"), .insertion(.unverified))
    }

    func testReportJSONCarriesCountersAndRoundTrips() throws {
        let store = try TranscriptStore(directory: directory)
        try store.countUsage([.savedDictationReviewed], at: date(9), calendar: calendar)
        let report = try store.activity(now: date(9), calendar: calendar)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
        XCTAssertEqual(json["counters"] as? [String: Int], ["savedDictation.reviewed": 1])
        let daily = try XCTUnwrap(json["daily"] as? [[String: Any]])
        XCTAssertEqual(daily.last?["counters"] as? [String: Int], ["savedDictation.reviewed": 1])
        XCTAssertEqual(daily.first?["counters"] as? [String: Int], [:])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ActivityReport.self, from: encoder.encode(report)), report)
    }
}
