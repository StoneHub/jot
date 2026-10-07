import XCTest
import JotCore
@testable import JotCLI

final class ListenCommandTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(_ id: String, _ text: String, at seconds: Double = 1) -> Transcript {
        .init(id: id, sessionID: "session", startedAt: base, startSeconds: seconds, endSeconds: seconds + 1,
              text: text, speakerID: "s1", mode: "ambient")
    }
    private func envelope<T: Encodable>(_ result: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(result))
        return try JSONSerialization.data(withJSONObject: ["ok": true, "result": object])
    }
    private func object(_ result: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }

    func testFlagsOverrideSavedDefaultsAndInvalidSavedValuesFallBack() throws {
        let defaults: [[String: Any]] = [["key": JotSettings.listenWakePhrases, "value": "cloud"], ["key": JotSettings.listenMode, "value": "context"],
                                       ["key": JotSettings.listenQuietGap, "value": 10.0], ["key": JotSettings.listenLookbackMinutes, "value": 8]]
        let config = try ListenOptions(["--mode", "fast", "--wake", "hey Claude,assistant", "--quiet-gap", "3", "--lookback-minutes", "2"]).configuration(defaults)
        XCTAssertEqual(config.mode, .fast); XCTAssertEqual(config.wakePhrases, ["hey Claude", "assistant"])
        XCTAssertEqual(config.quietGap, 3); XCTAssertEqual(config.lookbackMinutes, 2)
        let fallback = try ListenOptions([]).configuration([["key": JotSettings.listenWakePhrases, "value": ","], ["key": JotSettings.listenMode, "value": "nonsense"]])
        XCTAssertEqual(fallback.mode, .command); XCTAssertEqual(fallback.wakePhrases, ["claude"])
    }
    func testInvalidFlagsRefusedBeforeAnyRequest() {
        for args in [["--mode", "bad"], ["--wake", ""], ["--wake", "claude,,cloud"], ["--quiet-gap", "2"], ["--timeout", "nan"], ["--timeout", "-1"], ["--lookback-minutes", "0"], ["--once", "--once"], ["--unexpected", "1"], ["--mode"]] {
            var requests = 0
            let command = ListenCommand(request: { _, _, _ in requests += 1; throw ListenError("unexpected") })
            XCTAssertThrowsError(try command.run(args), String(describing: args)); XCTAssertEqual(requests, 0)
        }
    }
    func testStartsAtHeadPreservesGenerationAndOnceStopsFirstEvent() throws {
        var calls = 0, lines: [String] = []
        let command = ListenCommand(request: { method, params, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            XCTAssertEqual(method, "transcripts.since")
            calls += 1
            if calls == 1 { XCTAssertNil(params["cursor"]); return try self.envelope(TranscriptChanges(rows: [], cursor: 100, hasMore: false, generation: "db")) }
            XCTAssertEqual(params["cursor"] as? Int64, 100); XCTAssertEqual(params["generation"] as? String, "db")
            return try self.envelope(TranscriptChanges(rows: [.init(self.row("new", "Claude do"), sequence: 101), .init(self.row("second", "Claude another", at: 3), sequence: 102)], cursor: 102, hasMore: false, generation: "db"))
        }, wallTime: { self.base }, output: { lines.append($0) })
        try command.run(["--mode", "fast", "--once"])
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines[0].contains("Claude do")); XCTAssertEqual(calls, 2)
    }
    func testPagingDoesNotPrematurelyFinishCommandAndCleanupDoesNotAppend() throws {
        var now = 0.0, polls = 0, sleeps: [Double] = [], lines: [String] = []
        let command = ListenCommand(request: { method, _, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            if method == "speech.status" { return try self.object(["mode": "ambient"]) }
            polls += 1
            switch polls {
            case 1: return try self.envelope(TranscriptChanges(rows: [], cursor: 0, hasMore: false))
            case 2: return try self.envelope(TranscriptChanges(rows: [.init(self.row("a", "Claude start"), sequence: 1)], cursor: 1, hasMore: true))
            case 3:
                now = 10 // pages can be slow, but must be drained before deciding quiet
                return try self.envelope(TranscriptChanges(rows: [.init(self.row("b", "then finish", at: 2), sequence: 2)], cursor: 2, hasMore: false))
            case 4: return try self.envelope(TranscriptChanges(rows: [.init(self.row("a", "Claude, start"), sequence: 3)], cursor: 3, hasMore: false))
            default: return try self.envelope(TranscriptChanges(rows: [], cursor: 3, hasMore: false))
            }
        }, uptime: { now }, wallTime: { self.base }, sleep: { sleeps.append($0); now += $0 }, output: { lines.append($0) })
        try command.run(["--once", "--timeout", "30"])
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines[0].contains("Claude, start then finish"))
        XCTAssertEqual(now, 16); XCTAssertTrue(sleeps.allSatisfy { $0 == 2 })
    }
    func testTimeoutIsQuietAndPollNeverFasterThanTwoSeconds() throws {
        var now = 0.0, lines: [String] = [], delays: [Double] = []
        let command = ListenCommand(request: { method, _, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            if method == "speech.status" { return try self.object(["mode": "ambient"]) }
            var page = TranscriptChanges(rows: [], cursor: 42, hasMore: false); page.pollAfterSeconds = 0.1
            return try self.envelope(page)
        }, uptime: { now }, wallTime: { self.base }, sleep: { delays.append($0); now += $0 }, output: { lines.append($0) })
        try command.run(["--timeout", "5"])
        XCTAssertEqual(lines, []); XCTAssertEqual(delays, [2, 2, 1]); XCTAssertEqual(now, 5)
    }
    func testZeroTimeoutMakesNoRequest() throws {
        var called = false
        try ListenCommand(request: { _, _, _ in called = true; throw ListenError("unavailable") }).run(["--timeout", "0"])
        XCTAssertFalse(called)
    }
    func testUnavailableAndServerErrorPropagateAsOneError() throws {
        XCTAssertThrowsError(try ListenCommand(request: { _, _, _ in throw LocalServiceError.unavailable("Jot is not running") }).run([]))
        let response = try JSONSerialization.data(withJSONObject: ["ok": false, "error": "database unavailable"])
        XCTAssertThrowsError(try ListenCommand(request: { _, _, _ in response }).run([])) { XCTAssertEqual($0.localizedDescription, "database unavailable") }
    }
    func testPauseNoticeOnlyOnceUntilResume() throws {
        var now = 0.0, statuses = 0, lines: [String] = []
        let command = ListenCommand(request: { method, _, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            if method == "speech.status" {
                statuses += 1
                return try self.object(["mode": statuses == 3 ? "ambient" : "paused"])
            }
            return try self.envelope(TranscriptChanges(rows: [], cursor: 0, hasMore: false))
        }, uptime: { now }, wallTime: { self.base }, sleep: { now += $0 }, output: { lines.append($0) })
        try command.run(["--timeout", "8"])
        XCTAssertEqual(lines.count, 2); XCTAssertTrue(lines.allSatisfy { $0.contains("paused") })
    }
    func testResetResubscribesAtHeadAndSkipsReplay() throws {
        var now = 0.0, polls = 0, lines: [String] = []
        let command = ListenCommand(request: { method, params, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            polls += 1
            switch polls {
            case 1: return try self.envelope(TranscriptChanges(rows: [], cursor: 100, hasMore: false, generation: "old"))
            case 2: return try self.envelope(TranscriptChanges(rows: [.init(self.row("history", "Claude replay"), sequence: 1)], cursor: 1, hasMore: false, reset: true, generation: "new"))
            case 3: XCTAssertNil(params["cursor"]); return try self.envelope(TranscriptChanges(rows: [], cursor: 20, hasMore: false, generation: "new"))
            default: XCTAssertEqual(params["generation"] as? String, "new"); return try self.envelope(TranscriptChanges(rows: [.init(self.row("live", "Claude live"), sequence: 21)], cursor: 21, hasMore: false, generation: "new"))
            }
        }, uptime: { now }, wallTime: { self.base }, sleep: { now += $0 }, output: { lines.append($0) })
        try command.run(["--mode", "fast", "--once", "--timeout", "10"])
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines[0].contains("Claude live"))
    }
    func testContextSnapshotFollowsHeadAndCannotWake() throws {
        var now = 0.0, methods: [String] = [], polls = 0, lines: [String] = []
        let command = ListenCommand(request: { method, _, _ in
            methods.append(method)
            if method == "settings.get" { return try self.object(["settings": []]) }
            if method == "transcripts.recent" { return try self.envelope([self.row("history", "Claude prior", at: -10)]) }
            if method == "speech.status" { return try self.object(["mode": "ambient"]) }
            polls += 1
            if polls == 1 { return try self.envelope(TranscriptChanges(rows: [], cursor: 10, hasMore: false)) }
            return try self.envelope(TranscriptChanges(rows: polls == 2 ? [.init(self.row("live", "Claude use prior"), sequence: 11)] : [], cursor: 11, hasMore: false))
        }, uptime: { now }, wallTime: { self.base }, sleep: { now += $0 }, output: { lines.append($0) })
        try command.run(["--mode", "context", "--once", "--timeout", "10"])
        XCTAssertEqual(Array(methods.prefix(3)), ["settings.get", "transcripts.since", "transcripts.recent"])
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines[0].contains("Claude prior")); XCTAssertTrue(lines[0].contains("Claude use prior"))
    }
    func testDeletionBetweenHeadAndSnapshotIsReconciledBeforeContextOutput() throws {
        var now = 0.0, polls = 0, lines: [String] = [], snapshotRead = false
        let command = ListenCommand(request: { method, params, _ in
            if method == "settings.get" { return try self.object(["settings": []]) }
            if method == "transcripts.recent" { snapshotRead = true; return try self.envelope([self.row("deleted", "stale private context", at: -10)]) }
            if method == "speech.status" { return try self.object(["mode": "ambient"]) }
            polls += 1
            if polls == 1 { return try self.envelope(TranscriptChanges(rows: [], cursor: snapshotRead ? 101 : 100, hasMore: false)) }
            if polls == 2 {
                let deleted: [TranscriptDeletion] = params["cursor"] as? Int64 == 100 ? [.init(id: "deleted", sessionID: "session", sequence: 101)] : []
                return try self.envelope(TranscriptChanges(rows: [.init(self.row("live", "Claude current"), sequence: 102)], cursor: 102, hasMore: false,
                    deleted: deleted))
            }
            return try self.envelope(TranscriptChanges(rows: [], cursor: 102, hasMore: false))
        }, uptime: { now }, wallTime: { self.base }, sleep: { now += $0 }, output: { lines.append($0) })
        try command.run(["--mode", "context", "--once", "--timeout", "10"])
        XCTAssertEqual(lines.count, 1); XCTAssertFalse(lines[0].contains("stale private context"))
    }
    func testSocketDeadlineExpiryIsQuietButEarlyFailuresRemainErrors() throws {
        var now = 0.0, lines: [String] = []
        let command = ListenCommand(request: { _, _, timeout in
            XCTAssertEqual(timeout, 1)
            now = 1
            throw LocalServiceError.unavailable("socket timed out")
        }, uptime: { now }, output: { lines.append($0) })
        XCTAssertNoThrow(try command.run(["--timeout", "0.5"]))
        XCTAssertEqual(lines, [])
    }

}
