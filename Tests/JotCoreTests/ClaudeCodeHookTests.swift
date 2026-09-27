import XCTest
@testable import JotCore

/// Synthetic hook payloads and transcripts shaped like Claude Code 2.1's: one JSON object per line, each assistant
/// block on its own line, tool results as user lines.
final class ClaudeCodeHookTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-claude-hook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func user(_ content: Any, extra: [String: Any] = [:]) -> String {
        line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": content]].merging(extra) { $1 })
    }
    private func assistant(_ block: [String: Any], extra: [String: Any] = [:]) -> String {
        line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [block]]].merging(extra) { $1 })
    }
    private func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    private let toolUse: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift test"]]
    private let toolResult: [[String: Any]] = [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]
    private func turn(_ lines: [String]) -> ClaudeCodeTranscript.Turn {
        ClaudeCodeTranscript.lastTurn(in: Data(lines.joined(separator: "\n").utf8))
    }

    func testLastTurnIsTheTypedPromptAndTheFinalMessage() {
        let lines = [
            line(["type": "last-prompt", "lastPrompt": "ignored"]),
            user("First prompt as a string"),
            assistant(text("First answer.")),
            line(["type": "attachment", "attachment": ["type": "file"]]),
            user([text("<system-reminder>Not the user's words.</system-reminder>"), text("Second prompt in blocks")]),
            assistant(["type": "thinking", "thinking": "Planning."]),
            assistant(text("Let me run the tests.")),
            assistant(toolUse),
            user("A subagent's task", extra: ["isSidechain": true]),
            assistant(text("A subagent's answer."), extra: ["isSidechain": true]),
            user(toolResult, extra: ["toolUseResult": ["stdout": "ok"]]),
            user("<task-notification>Background task finished</task-notification>", extra: ["origin": ["kind": "task-notification"]]),
            user("Skill body expanded for the model", extra: ["isMeta": true]),
            assistant(["type": "thinking", "thinking": "They pass."]),
            assistant(text("The tests pass.")),
            assistant(text("Should I open a PR?")),
            line(["type": "system", "subtype": "stop_hook_summary"]),
            "{not json",
        ]
        XCTAssertEqual(turn(lines), .init(prompt: "Second prompt in blocks", reply: "The tests pass.\n\nShould I open a PR?"),
                       "Narration before the last tool call, sidechains, tool results, notifications and meta lines are not the turn's words")
        XCTAssertEqual(turn(Array(lines[0...3])), .init(prompt: "First prompt as a string", reply: "First answer."))
    }

    func testTurnsWithoutAFinalMessage() {
        XCTAssertEqual(turn([user("Run it"), assistant(toolUse), user(toolResult)]), .init(prompt: "Run it", reply: nil),
                       "A turn with no text has no reply")
        XCTAssertEqual(turn([user("Run it"), assistant(text("Starting.")), assistant(toolUse)]), .init(prompt: "Run it", reply: "Starting."),
                       "A turn that ends on a tool call keeps its last text")
        XCTAssertEqual(turn([assistant(text("Older narration.")), assistant(toolUse), user(toolResult), assistant(text("Done."))]),
                       .init(prompt: nil, reply: "Done."), "A prompt before the tail is missing, not guessed")
        XCTAssertEqual(turn([]), .init(prompt: nil, reply: nil))
    }

    func testGeneratedUserLinesAreNotPrompts() {
        let lines = [
            user("Real prompt", extra: ["origin": ["kind": "human"]]),
            assistant(text("Answer.")),
            user("<command-name>/clear</command-name>"),
            user("<local-command-stdout></local-command-stdout>"),
            user([text("[Request interrupted by user]")]),
            user("<bash-input>ls</bash-input>"),
            user("Peer message", extra: ["origin": ["kind": "peer"], "isMeta": true]),
            user("Summary of the earlier conversation", extra: ["isCompactSummary": true]),
            assistant(text("No response requested."), extra: ["message": ["role": "assistant", "model": "<synthetic>", "content": [text("No response requested.")]]]),
            assistant(text("API Error: overloaded"), extra: ["isApiErrorMessage": true]),
        ]
        XCTAssertEqual(turn(lines), .init(prompt: "Real prompt", reply: "Answer."))
    }

    func testTailStartsAtAWholeLineAndNeverReadsOtherFiles() throws {
        let file = directory.appendingPathComponent("session.jsonl")
        let lines = [user(String(repeating: "x", count: 400)), user("Recent prompt"), assistant(text("Recent answer."))]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let tail = try XCTUnwrap(ClaudeCodeHook.readTail(of: file.path, maximumBytes: 300))
        XCTAssertLessThanOrEqual(tail.count, 300)
        XCTAssertTrue(tail.starts(with: Data(#"{"#.utf8)), "The cut line is dropped")
        XCTAssertEqual(ClaudeCodeTranscript.lastTurn(in: tail), .init(prompt: "Recent prompt", reply: "Recent answer."))
        XCTAssertEqual(ClaudeCodeHook.readTail(of: file.path), try Data(contentsOf: file), "A small transcript is read whole")

        let other = directory.appendingPathComponent("notes.txt")
        try Data("secret".utf8).write(to: other)
        XCTAssertNil(ClaudeCodeHook.readTail(of: other.path))
        let folder = directory.appendingPathComponent("folder.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(ClaudeCodeHook.readTail(of: folder.path))
        XCTAssertNil(ClaudeCodeHook.readTail(of: directory.appendingPathComponent("missing.jsonl").path))
    }

    func testHookEventsBecomeUpdates() throws {
        func hook(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
        let common: [String: Any] = ["session_id": "abc", "cwd": "/tmp/project", "transcript_path": "/unused.jsonl"]

        let submitted = try XCTUnwrap(ClaudeCodeHook.update(fromHook: hook(common.merging(["hook_event_name": "UserPromptSubmit",
                                                                                            "prompt": "Explain the failure"]) { $1 })))
        XCTAssertEqual(submitted, ConversationUpdate(sessionID: "abc", event: .promptSubmitted, cwd: "/tmp/project",
                                                     prompt: "Explain the failure", reply: nil))

        let file = directory.appendingPathComponent("t.jsonl")
        try Data([user("Explain the failure"), assistant(text("The socket closed early."))].joined(separator: "\n").utf8).write(to: file)
        let stop = common.merging(["hook_event_name": "Stop", "stop_hook_active": false, "transcript_path": file.path]) { $1 }
        let stopped = try XCTUnwrap(ClaudeCodeHook.update(fromHook: hook(stop)))
        XCTAssertEqual(stopped.prompt, "Explain the failure")
        XCTAssertEqual(stopped.reply, "The socket closed early.")
        XCTAssertEqual(stopped.params["event"] as? String, "Stop")

        XCTAssertNil(ClaudeCodeHook.update(fromHook: hook(stop.merging(["agent_id": "sub-1", "agent_type": "Explore"]) { $1 })),
                     "A subagent's events are ignored")
        XCTAssertNotNil(ClaudeCodeHook.update(fromHook: hook(stop.merging(["agent_type": "main-agent"]) { $1 })),
                        "An agent type alone names the main session's agent")
        XCTAssertNil(ClaudeCodeHook.update(fromHook: hook(stop.merging(["hook_event_name": "SubagentStop"]) { $1 })))
        XCTAssertNil(ClaudeCodeHook.update(fromHook: hook(stop.merging(["transcript_path": directory.appendingPathComponent("gone.jsonl").path]) { $1 })))
        XCTAssertNil(ClaudeCodeHook.update(fromHook: hook(["hook_event_name": "Stop"])), "No session, no update")
        XCTAssertNil(ClaudeCodeHook.update(fromHook: Data("not json".utf8)))
        XCTAssertNil(ClaudeCodeHook.update(fromHook: hook(common.merging(["hook_event_name": "UserPromptSubmit", "prompt": 42]) { $1 })),
                     "A field of the wrong type is ignored")

        let empty = directory.appendingPathComponent("empty.jsonl")
        try Data([user("Run it"), assistant(toolUse)].joined(separator: "\n").utf8).write(to: empty)
        XCTAssertEqual(ClaudeCodeHook.update(fromHook: hook(stop.merging(["transcript_path": empty.path]) { $1 }))?.reply, nil)
    }
}
