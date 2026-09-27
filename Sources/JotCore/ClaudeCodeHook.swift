import Darwin
import Foundation

/// Turns a Claude Code hook's stdin into a `conversation.update`. Every field is optional: anything unexpected
/// yields no update rather than an error, because the hook must never disturb Claude.
public enum ClaudeCodeHook {
    public static let method = "conversation.update"
    /// Read from the end of the transcript: a turn's final message and, unless the turn's tool output is huge, its prompt.
    public static let transcriptTailBytes = 512 * 1024

    public static func update(fromHook data: Data,
                              transcriptTail: (String) -> Data? = { readTail(of: $0) }) -> ConversationUpdate? {
        guard let hook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = hook["session_id"] as? String,
              let event = (hook["hook_event_name"] as? String).flatMap(ConversationUpdate.Event.init(rawValue:)) else { return nil }
        // A subagent works on its own task, not the conversation the user is in.
        guard hook["agent_id"] == nil else { return nil }
        let cwd = hook["cwd"] as? String
        switch event {
        case .promptSubmitted:
            return ConversationUpdate(sessionID: sessionID, event: event, cwd: cwd, prompt: hook["prompt"] as? String, reply: nil)
        case .stopped:
            // Stop does not carry the reply; the transcript it names does.
            guard let path = hook["transcript_path"] as? String, let tail = transcriptTail(path) else { return nil }
            let turn = ClaudeCodeTranscript.lastTurn(in: tail)
            return ConversationUpdate(sessionID: sessionID, event: event, cwd: cwd, prompt: turn.prompt, reply: turn.reply)
        }
    }

    /// The last `maximumBytes` of a regular `.jsonl` file, starting at a whole line. Never reads the whole transcript.
    public static func readTail(of path: String, maximumBytes: Int = transcriptTailBytes) -> Data? {
        guard path.hasSuffix(".jsonl") else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let offset = max(0, Int(info.st_size) - maximumBytes)
        var data = Data(count: Int(info.st_size) - offset)
        var filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + filled, $0.count - filled, off_t(offset + filled)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            filled += count
        }
        data = data.prefix(filled)
        guard offset > 0 else { return data }
        guard let newline = data.firstIndex(of: 10) else { return Data() }
        return Data(data[(newline + 1)...])
    }
}

/// Reads the last turn from the end of a Claude Code transcript (JSONL). Each line has a `type`, `isSidechain` and a
/// `message` whose `content` is a string or blocks; each assistant block is its own line, and tool results come back
/// as `user` lines. Unknown lines and fields are skipped, so a format change loses the reply, never the hook.
public enum ClaudeCodeTranscript {
    public struct Turn: Equatable, Sendable {
        public var prompt: String?
        public var reply: String?
    }

    private enum Entry {
        case prompt(String)
        case text(String)
        case tool
    }

    /// The last prompt the user typed, and the turn's final message after it: the text after the turn's last tool
    /// call, since earlier text narrates the work. A turn that ends on a tool call keeps its last text.
    public static func lastTurn(in tail: Data) -> Turn {
        var entries: [Entry] = []
        for line in tail.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            entries += Self.entries(object)
        }
        var turn = entries[...]
        var prompt: String?
        if let start = entries.lastIndex(where: { if case .prompt = $0 { return true } else { return false } }) {
            if case .prompt(let text) = entries[start] { prompt = text }
            turn = entries[(start + 1)...]
        }
        let lastTool = turn.lastIndex { if case .tool = $0 { return true } else { return false } }
        let final = texts(turn[(lastTool.map { $0 + 1 } ?? turn.startIndex)...])
        let reply = final.isEmpty ? texts(turn).last : final.joined(separator: "\n\n")
        return Turn(prompt: prompt, reply: reply)
    }

    private static func texts(_ entries: ArraySlice<Entry>) -> [String] {
        entries.compactMap { entry in
            if case .text(let text) = entry { return text } else { return nil }
        }
    }

    /// Tagged text Claude Code writes as a user line but the user did not type as a prompt.
    private static let generatedTags = ["<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
                                        "<local-command-stderr>", "<local-command-caveat>", "<task-notification>",
                                        "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
                                        "<system-reminder>"]

    private static func entries(_ line: [String: Any]) -> [Entry] {
        guard line["isSidechain"] as? Bool != true, let message = line["message"] as? [String: Any] else { return [] }
        let blocks: [[String: Any]]
        if let text = message["content"] as? String { blocks = [["type": "text", "text": text]] }
        else { blocks = message["content"] as? [[String: Any]] ?? [] }
        switch line["type"] as? String {
        case "user":
            // Skill and command expansions, compaction summaries and notifications arrive as user lines too.
            guard line["isMeta"] as? Bool != true, line["isCompactSummary"] as? Bool != true,
                  line["isVisibleInTranscriptOnly"] as? Bool != true else { return [] }
            if let origin = line["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" { return [] }
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return [.tool] }
            let typed = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                let trimmed = withoutReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("[Request interrupted by user"),
                      !generatedTags.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
                return trimmed
            }
            return typed.isEmpty ? [] : [.prompt(typed.joined(separator: "\n\n"))]
        case "assistant":
            guard line["isApiErrorMessage"] as? Bool != true, message["model"] as? String != "<synthetic>" else { return [] }
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return .text(text)
                case "tool_use", "server_tool_use": return .tool
                default: return nil
                }
            }
        default: return []
        }
    }

    /// Claude Code appends reminders to what the user typed; they are not the user's words.
    private static func withoutReminders(_ text: String) -> String {
        var text = text
        while let start = text.range(of: "<system-reminder>"),
              let end = text.range(of: "</system-reminder>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }
}
