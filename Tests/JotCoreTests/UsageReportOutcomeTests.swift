import XCTest
@testable import JotCore

final class UsageReportOutcomeTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_795_000_000)
    private let days = ["2026-11-19", "2026-11-20"]

    func testHTTPAnswersSayWhetherTheDaysAreDone() {
        let sent = UsageReportOutcome.answer(204, body: Data(), days: days, at: at)
        XCTAssertEqual(sent.result, .sent)
        XCTAssertNil(sent.detail)
        XCTAssertTrue(sent.marksDays)

        let refused = UsageReportOutcome.answer(400, body: Data("invalid count".utf8), days: days, at: at)
        XCTAssertEqual(refused.result, .refused)
        XCTAssertEqual(refused.detail, "invalid count")
        XCTAssertTrue(refused.marksDays, "A refused report would be refused again, so its days are marked")

        for status in [429, 500, 503] {
            let failed = UsageReportOutcome.answer(status, body: Data(), days: days, at: at)
            XCTAssertEqual(failed.result, .failed, "\(status)")
            XCTAssertFalse(failed.marksDays, "\(status) is retried later")
            XCTAssertNil(failed.detail)
        }
    }

    func testDetailIsOneShortPrintableLine() {
        let page = "<html>\n<body>Proxy\tsign-in required é" + String(repeating: "x", count: 500) + "</body></html>"
        let outcome = UsageReportOutcome.answer(403, body: Data(page.utf8), days: days, at: at)
        let detail = outcome.detail ?? ""
        XCTAssertTrue(detail.hasPrefix("<html> <body>Proxy sign-in required x"))
        XCTAssertEqual(detail.count, UsageReportOutcome.maximumDetail)
        XCTAssertTrue(detail.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) })
    }

    func testSummaryNamesTheDaysAndStatus() {
        XCTAssertEqual(UsageReportOutcome.answer(204, body: Data(), days: days, at: at).summary, "sent 2026-11-19...2026-11-20 (HTTP 204)")
        XCTAssertEqual(UsageReportOutcome.answer(400, body: Data("invalid day".utf8), days: ["2026-11-19"], at: at).summary,
                       "refused 2026-11-19 (HTTP 400): invalid day")
        XCTAssertEqual(UsageReportOutcome(at: at, result: .nothingToSend).summary, "nothingToSend")
    }

    func testStoredFormRoundTrips() throws {
        let outcome = UsageReportOutcome.answer(400, body: Data("invalid count".utf8), days: days, at: at)
        XCTAssertEqual(UsageReportOutcome.decoded(try XCTUnwrap(outcome.encoded())), outcome)
        XCTAssertNil(UsageReportOutcome.decoded(nil))
        XCTAssertNil(UsageReportOutcome.decoded(Data("not json".utf8)))
    }
}
