import Foundation

/// A bounded, attributable message from a local agent hook. Invalid and incomplete events are ignored.
public struct AgentHook: Sendable, Equatable {
    public let role: String
    public let source: String
    public let conversation: String
    public let turn: String?
    public let cwd: String?
    public let text: String
    public let eventID: String?

    public static let maximumInputBytes = 128 * 1024

    public init?(source: String, data: Data) {
        guard ["claude-code", "codex"].contains(source), data.count <= Self.maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["agent_id"] == nil,
              let session = object["session_id"] as? String,
              !session.isEmpty, session.utf8.count <= 200,
              let event = object["hook_event_name"] as? String else { return nil }
        let role: String
        let rawText: String
        switch event {
        case "UserPromptSubmit":
            role = "user"
            guard let prompt = object["prompt"] as? String else { return nil }
            rawText = prompt
        case "Stop":
            role = "assistant"
            guard let reply = object["last_assistant_message"] as? String else { return nil }
            rawText = reply
        default: return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= AgentContext.maximumMessageBytes else { return nil }
        let rawTurn = source == "claude-code" ? object["prompt_id"] : object["turn_id"]
        let turn = (rawTurn as? String).flatMap { $0.isEmpty || $0.utf8.count > 200 ? nil : $0 }
        let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 1024 ? nil : $0 }
        self.source = source
        self.role = role
        self.conversation = session
        self.turn = turn
        self.cwd = cwd
        self.text = text
        // Only a provider's stable turn identity permits deduplication. Without one, identical
        // words may be a separate turn and must not disappear.
        self.eventID = turn.map { [source, session, $0, role, ContentHash.sha256(Data(text.utf8))].joined(separator: ":") }
    }
}
