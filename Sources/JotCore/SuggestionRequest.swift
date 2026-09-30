import Foundation

public enum ContextAssociation: Equatable, Sendable {
    case scoped
    /// Applies only to the rows supplied by an explicit recent-context request. Never changes their provenance.
    case explicitRecentRequest
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
