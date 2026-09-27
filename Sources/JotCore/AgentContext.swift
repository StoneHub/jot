import Foundation

/// Messages an agent conversation hands Jot over the socket: what the user typed and what the assistant answered.
/// They live in memory for the suggestion window and are never written to disk, so Jot's memory of them cannot grow.
public final class AgentContext: @unchecked Sendable {
    public static let kind = "agent-message"
    public static let roles = ["user", "assistant"]
    /// One message; longer text is refused rather than cut, so a negation or prerequisite is never lost.
    public static let maximumMessageBytes = 8_192
    /// All messages together, oldest dropped first, whatever the window says.
    public static let maximumBytes = 65_536
    public static let maximumMessages = 128

    public struct Message: Equatable, Sendable {
        public let id: String
        /// "user" or "assistant".
        public let role: String
        /// The app that sent it, such as claude-code or codex.
        public let source: String
        public let conversation: String?
        public let turn: String?
        public let cwd: String?
        public let text: String
        public let receivedAt: Date
        /// Stable identity for a retried hook event. Explicit context.add messages have none.
        public let eventID: String?
    }

    private let lock = NSLock()
    private var messages: [Message] = []
    private var next = 1

    public init() {}

    /// Keeps the message and returns it. Throws for an unknown role, blank text, or text over the per-message bound.
    @discardableResult
    public func add(role: String, source: String, conversation: String? = nil, text: String,
                    turn: String? = nil, cwd: String? = nil, eventID: String? = nil,
                    now: Date = Date()) throws -> Message {
        guard Self.roles.contains(role) else { throw AgentContextError.invalid("role must be user or assistant") }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, trimmedSource.utf8.count <= 64 else { throw AgentContextError.invalid("source must name the app, in 64 bytes or fewer") }
        guard conversation == nil || (conversation!.utf8.count <= 200 && !conversation!.isEmpty),
              turn == nil || (turn!.utf8.count <= 200 && !turn!.isEmpty),
              cwd == nil || (cwd!.utf8.count <= 1024 && !cwd!.isEmpty),
              eventID == nil || (eventID!.utf8.count <= 512 && !eventID!.isEmpty) else {
            throw AgentContextError.invalid("agent context metadata is invalid or too long")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentContextError.invalid("text is empty") }
        guard trimmed.utf8.count <= Self.maximumMessageBytes else { throw AgentContextError.invalid("text is over \(Self.maximumMessageBytes) bytes") }
        return lock.withLock {
            if let eventID, let existing = messages.first(where: { $0.eventID == eventID }) { return existing }
            let message = Message(id: "agent-\(next)", role: role, source: trimmedSource,
                                  conversation: conversation, turn: turn, cwd: cwd, text: trimmed,
                                  receivedAt: now, eventID: eventID)
            next += 1
            messages.append(message)
            var bytes = messages.reduce(0) { $0 + $1.text.utf8.count }
            while bytes > Self.maximumBytes || messages.count > Self.maximumMessages {
                bytes -= messages.removeFirst().text.utf8.count
            }
            return message
        }
    }

    /// Messages received within `window` seconds before `now`, oldest first. Older ones are dropped for good.
    public func messages(within window: TimeInterval, now: Date = Date()) -> [Message] {
        lock.withLock {
            messages.removeAll { $0.receivedAt < now.addingTimeInterval(-window) }
            return messages.filter { $0.receivedAt <= now }
        }
    }

    /// The same messages as suggestion sources. The revision is the message id, since a message never changes.
    public func sources(within window: TimeInterval, now: Date = Date()) -> [Source] {
        let formatter = ISO8601DateFormatter()
        return messages(within: window, now: now).map { message in
            Source(id: message.id, kind: Self.kind, role: message.role, origin: message.source,
                   scope: Source.Scope(project: message.cwd, conversation: message.conversation),
                   timestamp: formatter.string(from: message.receivedAt),
                   revision: Int(message.id.dropFirst("agent-".count)) ?? 1, status: .current, text: message.text)
        }
    }

    /// Agent text is used only when one conversation's assistant reply visibly matches this field's own window.
    /// A matching app alone is insufficient when several sessions are open.
    public func sources(within window: TimeInterval, now: Date = Date(),
                        targetBundleID: String, visibleText: String?) -> [Source] {
        guard let visibleText, !visibleText.isEmpty else { return [] }
        let appSources: Set<String>
        switch targetBundleID {
        case "com.openai.codex": appSources = ["codex"]
        case "com.anthropic.claudefordesktop": appSources = ["claude-code"]
        case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
             "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm":
            appSources = ["claude-code", "codex"]
        default: return []
        }
        let candidates = messages(within: window, now: now).filter {
            appSources.contains($0.source) && $0.conversation != nil
        }
        let visibleRuns = Set(Self.wordRuns(visibleText))
        guard !visibleRuns.isEmpty else { return [] }
        let conversations = Dictionary(grouping: candidates, by: { $0.source + "\u{0}" + $0.conversation! })
        let matches = conversations.filter { _, items in
            guard let reply = items.last(where: { $0.role == "assistant" }) else { return false }
            let runs = Self.wordRuns(reply.text)
            return runs.contains(where: visibleRuns.contains)
        }
        guard matches.count == 1, let conversation = matches.keys.first else { return [] }
        let allowed = Set(matches[conversation]!.map(\.id))
        return sources(within: window, now: now).filter { allowed.contains($0.id) }
    }

    private static func wordRuns(_ value: String) -> [String] {
        let words = value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count >= 8 else { return [] }
        let common: Set<String> = ["about", "after", "again", "could", "every", "first", "hello", "there", "these",
                                   "thing", "those", "today", "would", "which", "while", "their", "where", "please"]
        return (0...(words.count - 8)).compactMap { index in
            let run = Array(words[index..<(index + 8)])
            let distinctive = run.filter { $0.count >= 5 && !common.contains($0) }
            return Set(distinctive).count >= 3 ? run.joined(separator: " ") : nil
        }
    }

    public var count: Int { lock.withLock { messages.count } }

    /// Selected sources must still exist, and the same conversation must have no newer message.
    /// Expiry of an unselected older message and other conversations do not dismiss a card.
    public func matchesSnapshot(_ selected: [Source], latestID: String, within window: TimeInterval,
                                now: Date = Date()) -> Bool {
        guard let first = selected.first, let conversation = first.scope.conversation else { return false }
        let current = sources(within: window, now: now).filter {
            $0.origin == first.origin && $0.scope.conversation == conversation
        }
        guard current.last?.id == latestID else { return false }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return selected.allSatisfy { byID[$0.id] == $0 }
    }

    public func clear() { lock.withLock { messages.removeAll() } }
}

public enum AgentContextError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
