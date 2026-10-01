import JotCore

/// A preview belongs to one exact input revision and one set of source revisions.
public struct Preview: Equatable {
    public let inputRevision: Int
    public let before: String
    public let after: String
    public let sources: [SourceRevision]

    public init(for input: SuggestionRequest, sources: [SourceRevision]) {
        inputRevision = input.target.inputRevision
        before = input.target.before
        after = input.target.after
        self.sources = sources
    }

    /// Acceptance rereads the target. Any input edit, including a same-length one, or a revised, stale
    /// or deleted source withdraws the preview.
    public func isCurrent(for input: SuggestionRequest) -> Bool {
        guard input.target.inputRevision == inputRevision, input.target.before == before, input.target.after == after else {
            return false
        }
        return sources.allSatisfy { reference in
            input.sources.contains { $0.id == reference.id && $0.revision == reference.revision && $0.status == .current }
        }
    }
}
