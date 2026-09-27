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

    public struct Message: Equatable, Sendable {
        public let id: String
        /// "user" or "assistant".
        public let role: String
        /// The app that sent it, such as claude-code or codex.
        public let source: String
        public let conversation: String?
        public let text: String
        public let receivedAt: Date
    }

    private let lock = NSLock()
    private var messages: [Message] = []
    private var next = 1

    public init() {}

    /// Keeps the message and returns it. Throws for an unknown role, blank text, or text over the per-message bound.
    @discardableResult
    public func add(role: String, source: String, conversation: String? = nil, text: String, now: Date = Date()) throws -> Message {
        guard Self.roles.contains(role) else { throw AgentContextError.invalid("role must be user or assistant") }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, trimmedSource.utf8.count <= 64 else { throw AgentContextError.invalid("source must name the app, in 64 bytes or fewer") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentContextError.invalid("text is empty") }
        guard trimmed.utf8.count <= Self.maximumMessageBytes else { throw AgentContextError.invalid("text is over \(Self.maximumMessageBytes) bytes") }
        return lock.withLock {
            let message = Message(id: "agent-\(next)", role: role, source: trimmedSource,
                                  conversation: conversation?.isEmpty == false ? conversation : nil, text: trimmed, receivedAt: now)
            next += 1
            messages.append(message)
            var bytes = messages.reduce(0) { $0 + $1.text.utf8.count }
            while bytes > Self.maximumBytes, !messages.isEmpty { bytes -= messages.removeFirst().text.utf8.count }
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
                   scope: Source.Scope(conversation: message.conversation),
                   timestamp: formatter.string(from: message.receivedAt),
                   revision: Int(message.id.dropFirst("agent-".count)) ?? 1, status: .current, text: message.text)
        }
    }

    public var count: Int { lock.withLock { messages.count } }

    public func clear() { lock.withLock { messages.removeAll() } }
}

public enum AgentContextError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
