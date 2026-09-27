import Foundation

/// One Claude Code hook event as `jot claude-context` sends it over `conversation.update`. Texts are capped here
/// whatever the sender did: a prompt keeps its start, where the ask is; a reply keeps its end, where Claude's
/// conclusion or question to the user is.
public struct ConversationUpdate: Equatable, Sendable {
    public enum Event: String, Sendable {
        case promptSubmitted = "UserPromptSubmit"
        case stopped = "Stop"
    }
    public let sessionID: String
    public let event: Event
    public let cwd: String?
    public let prompt: String?
    public let reply: String?

    /// Nil without a session, or when the event carries no words.
    public init?(sessionID: String, event: Event, cwd: String? = nil, prompt: String?, reply: String?) {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200 else { return nil }
        let prompt = ConversationContext.capped(prompt, keepingEnd: false)
        let reply = event == .stopped ? ConversationContext.capped(reply, keepingEnd: true) : nil
        guard prompt != nil || reply != nil else { return nil }
        self.sessionID = id; self.event = event; self.prompt = prompt; self.reply = reply
        self.cwd = cwd.flatMap { $0.isEmpty || $0.count > 1024 ? nil : $0 }
    }

    public init?(params: [String: Any]) {
        guard let id = params["sessionID"] as? String,
              let event = (params["event"] as? String).flatMap(Event.init(rawValue:)) else { return nil }
        self.init(sessionID: id, event: event, cwd: params["cwd"] as? String,
                  prompt: params["prompt"] as? String, reply: params["reply"] as? String)
    }

    public var params: [String: Any] {
        var params: [String: Any] = ["sessionID": sessionID, "event": event.rawValue]
        if let cwd { params["cwd"] = cwd }
        if let prompt { params["prompt"] = prompt }
        if let reply { params["reply"] = reply }
        return params
    }
}

/// The latest exchanges of a few recent Claude Code sessions, as the plugin's hooks report them, so a suggestion in
/// Claude's composer knows the conversation it replies to. Memory only: never written to the database or disk, not
/// an MCP tool, and gone when Jot quits.
public struct ConversationContext: Sendable {
    public static let kind = "claude-code-conversation"
    public static let maximumSessions = 4
    public static let maximumExchanges = 3
    public static let maximumCharacters = 4000
    /// A session not heard from in this long is dropped.
    public static let lifetime: TimeInterval = 3600
    /// A terminal shows much besides Claude Code, so only a conversation this fresh is taken to be the one in it.
    public static let terminalWindow: TimeInterval = 300
    /// Like `ScreenContext.maximumBytes`: leaves room for recent dictation within the selector's 4 KiB bound.
    public static let maximumSourceBytes = 2400

    public struct Exchange: Equatable, Sendable {
        public var prompt: String?
        public var reply: String?
        public var at: Date
        public var repliedAt: Date?
    }

    public struct Session: Equatable, Sendable {
        public let id: String
        public var cwd: String?
        /// Oldest first.
        public var exchanges: [Exchange]
        public var updatedAt: Date
    }

    /// Where Claude Code's conversation can be the one a field replies to.
    public enum Surface: Sendable {
        case claudeApp, terminal
        public init?(bundleID: String) {
            switch bundleID {
            case "com.anthropic.claudefordesktop": self = .claudeApp
            case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                 "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm": self = .terminal
            default: return nil
            }
        }
    }

    /// Newest first.
    public private(set) var sessions: [Session] = []
    public init() {}

    public mutating func record(_ update: ConversationUpdate, at now: Date) {
        sessions.removeAll { now.timeIntervalSince($0.updatedAt) > Self.lifetime }
        var session = sessions.first { $0.id == update.sessionID }
            ?? Session(id: update.sessionID, cwd: nil, exchanges: [], updatedAt: now)
        sessions.removeAll { $0.id == update.sessionID }
        session.cwd = update.cwd ?? session.cwd
        session.updatedAt = now
        switch update.event {
        case .promptSubmitted:
            if let prompt = update.prompt { session.exchanges.append(Exchange(prompt: prompt, reply: nil, at: now)) }
        case .stopped:
            session.finish(prompt: update.prompt, reply: update.reply, at: now)
        }
        session.exchanges = Array(session.exchanges.suffix(Self.maximumExchanges))
        guard !session.exchanges.isEmpty else { return }
        sessions.insert(session, at: 0)
        sessions = Array(sessions.prefix(Self.maximumSessions))
    }

    /// Sessions a suggestion in this app may reply to, newest first.
    public func sessions(for surface: Surface, at now: Date) -> [Session] {
        let window = surface == .terminal ? Self.terminalWindow : Self.lifetime
        return sessions.filter { now.timeIntervalSince($0.updatedAt) <= window }
    }

    /// The session a field replies to. Text shown above the field decides when it holds a conversation: the session
    /// whose words it shows, or none when it shows another one, such as a chat in Claude's other tab or a session
    /// without the plugin. Without shown text, the newest session.
    public static func session(among candidates: [Session], shown: String?) -> Session? {
        let screen = words(shown ?? "")
        guard screen.count >= 30 else { return candidates.first }
        let visible = Set(runs(screen))
        return candidates.first { session in
            let own = session.exchanges.flatMap { [$0.prompt, $0.reply].compactMap { $0 } }.flatMap { runs(words($0)) }
            let matched = own.filter(visible.contains).count
            return matched > 0 && matched >= min(2, own.count)
        }
    }

    /// For `jot status`: a count and an age, never text, paths or session IDs.
    public func metadata(at now: Date) -> [String: Any] {
        let live = sessions.filter { now.timeIntervalSince($0.updatedAt) <= Self.lifetime }
        var result: [String: Any] = ["sessions": live.count]
        if let newest = live.first { result["secondsSinceUpdate"] = Int(now.timeIntervalSince(newest.updatedAt)) }
        return result
    }

    static func capped(_ text: String?, keepingEnd: Bool) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return clip(text, within: maximumCharacters, keepingEnd: keepingEnd) { _ in 1 }
    }

    /// At most `maximumBytes` of UTF-8, whole characters, marked with an ellipsis where text was cut.
    static func clipped(_ text: String, maximumBytes: Int, keepingEnd: Bool) -> String {
        clip(text, within: maximumBytes, keepingEnd: keepingEnd) { $0.utf8.count }
    }

    private static func clip(_ text: String, within limit: Int, keepingEnd: Bool, size: (Character) -> Int) -> String {
        guard text.reduce(0, { $0 + size($1) }) > limit else { return text }
        let marker: Character = "…"
        var room = limit - size(marker), kept: [Character] = []
        for character in keepingEnd ? Array(text.reversed()) : Array(text) {
            room -= size(character)
            guard room >= 0 else { break }
            kept.append(character)
        }
        guard !kept.isEmpty else { return "" }
        return keepingEnd ? String(marker) + String(kept.reversed()) : String(kept) + String(marker)
    }

    private static func words(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Consecutive four-word runs. Markdown and line breaks between words, which the app renders away, don't break one.
    private static func runs(_ words: [String]) -> [String] {
        words.count < 4 ? [] : (0...(words.count - 4)).map { words[$0..<$0 + 4].joined(separator: " ") }
    }
}

extension ConversationContext.Session {
    /// The prompt a Stop reads back from the transcript is the turn's only record when its UserPromptSubmit never
    /// arrived, as when the plugin was installed mid-session; the submitted words win when both exist.
    mutating func finish(prompt: String?, reply: String?, at now: Date) {
        guard var last = exchanges.last else {
            exchanges.append(.init(prompt: prompt, reply: reply, at: now, repliedAt: reply == nil ? nil : now)); return
        }
        if last.reply == nil {
            last.prompt = last.prompt ?? prompt
            last.reply = reply; last.repliedAt = reply == nil ? nil : now
        } else if prompt == last.prompt {
            // Another Stop for the same turn, as when a hook kept Claude working, has the newer reply.
            guard let reply else { return }
            last.reply = reply; last.repliedAt = now
        } else {
            exchanges.append(.init(prompt: prompt, reply: reply, at: now, repliedAt: reply == nil ? nil : now)); return
        }
        exchanges[exchanges.count - 1] = last
    }

    /// The conversation as prompt sources, oldest first, within `maximumBytes`. The newest reply is what the user
    /// answers, so it keeps its end and the newest prompt its start, both clipped to fit. Older exchanges join whole
    /// or not at all, so nothing between them and the newest is missing.
    public func sources(maximumBytes: Int = ConversationContext.maximumSourceBytes) -> [Source] {
        let date = ISO8601DateFormatter()
        var remaining = maximumBytes
        var picked: [[Source]] = []
        for (index, exchange) in exchanges.enumerated().reversed() {
            var prompt = exchange.prompt, reply = exchange.reply
            if picked.isEmpty {
                let promptShare = min(prompt?.utf8.count ?? 0, remaining / 3)
                reply = reply.map { ConversationContext.clipped($0, maximumBytes: remaining - promptShare, keepingEnd: true) }
                remaining -= reply?.utf8.count ?? 0
                prompt = prompt.map { ConversationContext.clipped($0, maximumBytes: remaining, keepingEnd: false) }
                remaining -= prompt?.utf8.count ?? 0
            } else {
                let cost = (prompt?.utf8.count ?? 0) + (reply?.utf8.count ?? 0)
                guard cost <= remaining else { break }
                remaining -= cost
            }
            var pair: [Source] = []
            if let prompt, !prompt.isEmpty {
                pair.append(source("\(index)-prompt", role: "user", at: date.string(from: exchange.at), text: prompt))
            }
            if let reply, !reply.isEmpty {
                pair.append(source("\(index)-reply", role: "assistant", at: date.string(from: exchange.repliedAt ?? exchange.at), text: reply))
            }
            picked.insert(pair, at: 0)
        }
        return picked.flatMap { $0 }
    }

    private func source(_ suffix: String, role: String, at timestamp: String, text: String) -> Source {
        Source(id: "claude-code-\(suffix)", kind: ConversationContext.kind, role: role, origin: "claude-code",
               scope: Source.Scope(conversation: id), timestamp: timestamp,
               revision: Int(ContentHash.sha256(text).prefix(12), radix: 16) ?? 1, status: .current, text: text)
    }
}
