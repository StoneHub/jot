import XCTest
@testable import JotCore

final class UsageReportTests: XCTestCase {
    private let counts: [String: [String: Int]] = [
        "2026-10-18": ["dictation.completed": 2],
        "2026-10-19": ["dictation.completed": 3, "insertion.accessibility": 3, "insertion.failed": 0],
        "2026-10-20": [:],
        "2026-10-21": ["dictation.completed": 1],
    ]

    func testSendsOnlyFinishedDaysAfterTheLastReport() throws {
        let report = try XCTUnwrap(UsageReport.due(counts: counts, today: "2026-10-21", reportedThrough: "2026-10-18",
                                                   app: "0.3.4", os: "26.1", arch: "arm64"))
        XCTAssertEqual(report.days, [.init(day: "2026-10-19", counters: ["dictation.completed": 3, "insertion.accessibility": 3])],
                       "The reported day, an empty day, zero counts and today are left out")
        XCTAssertNil(UsageReport.due(counts: counts, today: "2026-10-21", reportedThrough: "2026-10-20", app: "0.3.4", os: "26.1", arch: "arm64"))
    }

    func testKeepsTheNewestWeekAndOnlyNamesTheWorkerAccepts() throws {
        var many: [String: [String: Int]] = [:]
        for day in 1...10 { many[String(format: "2026-10-%02ld", day)] = ["dictation.completed": day, "dictation.madeUp": 1] }
        let report = try XCTUnwrap(UsageReport.due(counts: many, today: "2026-10-11", reportedThrough: "2026-09-30",
                                                   app: "0.3.4", os: "26.1", arch: "arm64"))
        XCTAssertEqual(report.days.map(\.day), (4...10).map { String(format: "2026-10-%02ld", $0) })
        XCTAssertTrue(report.days.allSatisfy { $0.counters.keys.sorted() == ["dictation.completed"] })
    }

    func testRefusesVersionsTheWorkerWouldRefuse() {
        for (app, os, arch) in [("0.3.4-beta", "26.1", "arm64"), ("0.3.4", "Darwin 26", "arm64"), ("0.3.4", "26.1", "ppc")] {
            XCTAssertNil(UsageReport.due(counts: counts, today: "2026-10-21", reportedThrough: "2026-10-01", app: app, os: os, arch: arch))
        }
        XCTAssertTrue(UsageReport.isVersion(UsageReport.osVersion), UsageReport.osVersion)
        XCTAssertTrue(UsageReport.isVersion(JotVersion.current))
    }

    /// The exact keys the Worker checks: any other field is refused there.
    func testJSONHasOnlyTheWorkerFields() throws {
        let report = try XCTUnwrap(UsageReport.due(counts: counts, today: "2026-10-21", reportedThrough: "2026-10-01",
                                                   app: "0.3.4", os: "26.1", arch: "arm64"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(json.keys.sorted(), ["app", "arch", "days", "os", "schema"])
        XCTAssertEqual(json["schema"] as? Int, 1)
        let day = try XCTUnwrap((json["days"] as? [[String: Any]])?.first)
        XCTAssertEqual(day.keys.sorted(), ["counters", "day"])
    }

    func testStoreReadsCountsForADayRange() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-usage-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let store = try TranscriptStore(directory: directory)
        for day in [18, 19, 21] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12)))
            try store.countUsage([.suggestionRequested], at: date, calendar: calendar)
        }
        XCTAssertEqual(try store.usageCounts(from: "2026-10-19", through: "2026-10-20"), ["2026-10-19": ["suggestion.requested": 1]])
    }

    /// The Worker answers only POST /v1/usage, over HTTPS.
    func testEndpointIsTheWorkersReportRoute() throws {
        let endpoint = try XCTUnwrap(UsageReport.endpoint)
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.path, "/v1/usage")
    }
}
