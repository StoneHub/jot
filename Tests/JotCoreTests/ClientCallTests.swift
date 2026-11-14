import XCTest
@testable import JotCore

/// Which programs called the socket, counted per day and method, kept 90 days, untouched by history deletion.
final class ClientCallTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-clients-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ day: Int, hour: Int = 9) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
    }

    func testCallsAreCountedPerDayProgramAndMethod() throws {
        let store = try TranscriptStore(directory: directory, key: .scratch)
        let agent = ClientCall(pid: 41, executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", method: "transcripts.recent")
        try store.recordClientCall(agent, at: try day(10), calendar: calendar)
        try store.recordClientCall(agent, at: try day(10, hour: 10), calendar: calendar)
        try store.recordClientCall(ClientCall(pid: 42, executablePath: "/usr/local/bin/jot", method: "speech.status"), at: try day(11), calendar: calendar)
        try store.recordClientCall(ClientCall(pid: 43, executablePath: nil, method: "transcripts.search"), at: try day(11), calendar: calendar)
        XCTAssertEqual(try store.clientCalls(days: 2, now: try day(11, hour: 18), calendar: calendar).map(\.count), [2, 1, 1])
        XCTAssertEqual(try store.clientCalls(days: 1, now: try day(11, hour: 18), calendar: calendar).map(\.count), [1, 1], "Today only")
        try store.recordClientCall(agent, at: try day(12), calendar: calendar)
        let week = try store.clientCalls(days: 7, now: try day(12, hour: 18), calendar: calendar)
        XCTAssertEqual(week.map(\.path), ["/Applications/Claude.app/Contents/MacOS/Claude", ClientCallSummary.unknownPath, "/usr/local/bin/jot"], "Most calls first, then by path")
        XCTAssertEqual(week.map(\.count), [3, 1, 1])
        XCTAssertEqual(week.first?.method, "transcripts.recent")
        XCTAssertEqual(week.first?.firstDay, "2026-11-10")
        XCTAssertEqual(week.first?.lastAt, try day(12))
    }

    func testOldRowsArePrunedAndHistoryDeletionLeavesTheLog() throws {
        let store = try TranscriptStore(directory: directory, key: .scratch)
        let call = ClientCall(pid: 1, executablePath: "/bin/agent", method: "transcripts.recent")
        try store.recordClientCall(call, at: try day(1), calendar: calendar)
        try store.append(Transcript(id: "a1", sessionID: "s1", startedAt: try day(1), startSeconds: 0, endSeconds: 1, text: "words", mode: "dictation"))
        try store.clearHistory()
        XCTAssertEqual(try store.clientCalls(days: 90, now: try day(2), calendar: calendar).count, 1)
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 91, to: try day(1)))
        try store.recordClientCall(call, at: later, calendar: calendar)
        XCTAssertEqual(try store.clientCalls(days: 90, now: later, calendar: calendar).map(\.count), [1], "The row from 91 days before is gone")
        XCTAssertEqual(try store.clientCalls(days: 500, now: later, calendar: calendar).map(\.count), [1], "Days are capped at 90")
    }
}
