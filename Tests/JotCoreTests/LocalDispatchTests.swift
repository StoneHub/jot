import XCTest
@testable import JotCore

/// The socket framing the app's `SpeechService.handle` uses, driven by a stub in place of the service.
@MainActor
final class LocalDispatchTests: XCTestCase {
    private func reply(_ request: String, _ respond: @MainActor (LocalRequest) async throws -> Any = { _ in ["fine": true] }) async throws -> [String: Any] {
        let data = await LocalDispatch.handle(Data(request.utf8), respond: respond)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRoutesTheMethodAndParamsToTheResponder() async throws {
        var seen: LocalRequest?
        let data = await LocalDispatch.handle(Data(#"{"method":"transcripts.search","params":{"query":"plan","limit":5}}"#.utf8)) { request in
            seen = request
            return ["b": 2, "a": 1]
        }
        XCTAssertEqual(seen?.method, .transcriptsSearch)
        XCTAssertEqual(seen?.params["query"] as? String, "plan")
        XCTAssertEqual(seen?.limit, 5)
        XCTAssertEqual(seen?.offset, 0)
        // The success envelope's keys are sorted at every level, so clients can compare replies byte for byte.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true,"result":{"a":1,"b":2}}"#)
    }

    func testMissingOrMalformedParamsReadAsEmpty() async throws {
        var seen: [LocalRequest] = []
        for request in [#"{"method":"speech.status"}"#, #"{"method":"speech.status","params":[1]}"#] {
            _ = try await reply(request) { seen.append($0); return [:] }
        }
        XCTAssertEqual(seen.map(\.params.count), [0, 0])
        XCTAssertEqual(seen.map(\.limit), [50, 50])
    }

    func testRefusesUnknownMethodsAndInvalidRequestsWithoutCallingTheResponder() async throws {
        var called = false
        let unknown = try await reply(#"{"method":"speech.explode"}"#) { _ in called = true; return [:] }
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertEqual(unknown["error"] as? String, "Unknown method: speech.explode")
        for invalid in [#"{"params":{}}"#, #"["speech.status"]"#, #"{"method":7}"#] {
            let refused = try await reply(invalid) { _ in called = true; return [:] }
            XCTAssertEqual(refused["error"] as? String, "Invalid request", invalid)
        }
        let garbled = await LocalDispatch.handle(Data("not json".utf8)) { _ in called = true; return [:] }
        XCTAssertEqual((try JSONSerialization.jsonObject(with: garbled) as? [String: Any])?["ok"] as? Bool, false)
        XCTAssertFalse(called)
    }

    func testResponderErrorsBecomeTheErrorText() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "sessionID is required" } }
        let refused = try await reply(#"{"method":"transcripts.export"}"#) { _ in throw Refused() }
        XCTAssertEqual(refused.count, 2)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "sessionID is required")
    }

    /// The wire names are the contract with the CLI, MCP clients and Vorssaint, so a rename fails here first.
    func testWireNamesAreStable() {
        XCTAssertEqual(LocalMethod.allCases.map(\.rawValue), [
            "speech.controls", "speech.status", "speech.diagnostics", "speech.start", "speech.pause", "speech.resume",
            "speech.meeting_start", "speech.meeting_end", "speech.transcribe_file", "activity.report",
            "models.prepare", "models.unload", "models.check", "sessions.title", "sessions.notes", "settings.get", "settings.set", "settings.reset",
            "transcripts.clear", "transcripts.delete_session", "transcripts.search", "transcripts.recent", "transcripts.events",
            "transcripts.sessions", "transcripts.since", "transcripts.wait", "transcripts.read", "transcripts.export", "suggestions.recent",
            "context.add", "context.hook", "context.clear", "people.list", "people.forget", "people.delete", "speakers.label", "vocabulary.list", "vocabulary.save", "vocabulary.remove",
        ])
        XCTAssertEqual(LocalMethod.allCases.filter(\.isLongRunning), [.speechStart, .speechMeetingStart, .speechMeetingEnd, .speechTranscribeFile, .modelsPrepare, .sessionsNotes, .transcriptsWait])
    }
}
