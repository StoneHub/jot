import Foundation

public enum ContextAssociation: Equatable, Sendable {
    case scoped
    /// Applies only to the rows supplied by an explicit recent-context request. Never changes their provenance.
    case explicitRecentRequest
    /// User-enabled automatic suggestions may use the same bounded recent rows.
    case automaticRecentContext
}

/// What an integration could know when the request is made; it carries no scenario ID or expectation.
public struct ScenarioInput: Equatable, Sendable {
    public init(target: Target, sources: [Source]) { self.target = target; self.sources = sources }
    public var association: ContextAssociation = .scoped
    public var target: Target
    public var sources: [Source]
}

public enum SuggestionMode: String, Decodable, CaseIterable, Sendable {
    case reply, continuation
    case shellCommand = "shell-command"
    /// Turn the user's rough notes (`Target.seed`) into finished text that replaces them.
    case draft
}

public struct Target: Decodable, Equatable, Sendable {
    public init(app: String, mode: SuggestionMode, purpose: String, project: String? = nil,
                conversation: String? = nil, cwd: String? = nil, inputRevision: Int = 0,
                before: String, after: String, requestedAt: String, seed: String? = nil, window: String? = nil) {
        self.app = app; self.mode = mode; self.purpose = purpose; self.project = project
        self.conversation = conversation; self.cwd = cwd; self.inputRevision = inputRevision
        self.before = before; self.after = after; self.requestedAt = requestedAt
        self.seed = seed; self.window = window
    }
    public var app: String
    public var mode: SuggestionMode
    public var purpose: String
    public var project: String?
    public var conversation: String?
    public var cwd: String?
    public var inputRevision: Int
    public var before: String
    public var after: String
    public var requestedAt: String
    /// Draft mode only: the user's notes that the result replaces. `before` and `after` are the field text around them.
    public var seed: String?
    /// Title of the focused window, when the app reports one.
    public var window: String?
}

public struct SourceRevision: Decodable, Equatable, Sendable, Hashable {
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
    public let id: String
    public let revision: Int
}

public struct Source: Decodable, Equatable, Sendable {
    public init(id: String, kind: String, role: String, speaker: String? = nil, origin: String,
                scope: Scope, timestamp: String, revision: Int, status: Status, text: String,
                derivedFrom: [SourceRevision]? = nil, duplicateOf: String? = nil) {
        self.id = id; self.kind = kind; self.role = role; self.speaker = speaker; self.origin = origin
        self.scope = scope; self.timestamp = timestamp; self.revision = revision; self.status = status
        self.text = text; self.derivedFrom = derivedFrom; self.duplicateOf = duplicateOf
    }
    public enum Status: String, Decodable, Sendable { case current, stale, deleted }
    public struct Scope: Decodable, Equatable, Sendable {
        public init(project: String? = nil, conversation: String? = nil, session: String? = nil) {
            self.project = project; self.conversation = conversation; self.session = session
        }
        public var project: String?
        public var conversation: String?
        public var session: String?
    }

    public let id: String
    public let kind: String
    public let role: String
    public let speaker: String?
    public let origin: String
    public let scope: Scope
    /// UTC `yyyy-MM-ddTHH:mm:ssZ`, so string order is time order.
    public let timestamp: String
    public var revision: Int
    public var status: Status
    public let text: String
    public let derivedFrom: [SourceRevision]?
    public let duplicateOf: String?
}
