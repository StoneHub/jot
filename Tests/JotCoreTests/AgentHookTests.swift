import Foundation
import XCTest
@testable import JotCore

final class AgentHookTests: XCTestCase {
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testClaudeAndCodexEventsKeepRolesAndIdentity() throws {
        let submit = try XCTUnwrap(AgentHook(source: "claude-code", data: data([
            "hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "prompt_id": "prompt-1", "prompt": "Fix the export guard"
        ])))
        XCTAssertEqual(submit.role, "user")
        XCTAssertEqual(submit.conversation, "claude-1")
        XCTAssertEqual(submit.text, "Fix the export guard")
        XCTAssertEqual(submit.turn, "prompt-1")
        XCTAssertEqual(submit.eventID, AgentHook(source: "claude-code", data: try data([
            "hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "prompt_id": "prompt-1", "prompt": "Fix the export guard"
        ]))?.eventID)
        let later = AgentHook(source: "claude-code", data: try data([
            "hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "prompt_id": "prompt-2", "prompt": "Fix the export guard"
        ]))
        XCTAssertNotEqual(submit.eventID, later?.eventID, "Identical words in a later turn are a new message")
        let stop = try XCTUnwrap(AgentHook(source: "codex", data: data([
            "hook_event_name": "Stop", "session_id": "codex-1", "turn_id": "turn-4",
            "last_assistant_message": "The tests pass; please review the change.", "cwd": "/tmp/project"
        ])))
        XCTAssertEqual(stop.role, "assistant")
        XCTAssertEqual(stop.turn, "turn-4")
        XCTAssertEqual(stop.cwd, "/tmp/project")
        XCTAssertEqual(stop.text, "The tests pass; please review the change.")
        let withoutStableID = AgentHook(source: "claude-code", data: try data([
            "hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "prompt": "yes"
        ]))
        XCTAssertNil(withoutStableID?.eventID, "Without a turn ID, do not collapse later identical prompts")
    }

    func testMissingReplyNeverReadsTranscriptOrInventsText() throws {
        let payload = try data(["hook_event_name": "Stop", "session_id": "c1", "transcript_path": "/private/ignored.jsonl"])
        XCTAssertNil(AgentHook(source: "claude-code", data: payload))
    }

    func testUnsupportedAndMalformedEventsAreIgnored() throws {
        let base: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "c1", "prompt": "hello"]
        XCTAssertNil(AgentHook(source: "other", data: try data(base)))
        XCTAssertNil(AgentHook(source: "codex", data: Data("not json".utf8)))
        XCTAssertNil(AgentHook(source: "codex", data: try data(["hook_event_name": "PreToolUse", "session_id": "c1", "prompt": "hello"])))
        var subagent = base; subagent["agent_id"] = "worker"
        XCTAssertNil(AgentHook(source: "claude-code", data: try data(subagent)))
        var namedRoot = base; namedRoot["agent_type"] = "custom-root"
        XCTAssertNotNil(AgentHook(source: "claude-code", data: try data(namedRoot)))
        var noSession = base; noSession.removeValue(forKey: "session_id")
        XCTAssertNil(AgentHook(source: "codex", data: try data(noSession)))
        var tooLong = base; tooLong["prompt"] = String(repeating: "a", count: AgentContext.maximumMessageBytes + 1)
        XCTAssertNil(AgentHook(source: "codex", data: try data(tooLong)))
        XCTAssertNil(AgentHook(source: "codex", data: Data(repeating: 65, count: AgentHook.maximumInputBytes + 1)))
    }
}
