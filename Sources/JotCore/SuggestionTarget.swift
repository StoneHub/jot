import Foundation

public struct SuggestionTarget: Decodable, Equatable, Sendable {
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
