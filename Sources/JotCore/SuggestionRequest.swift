import Foundation

/// The focused target and attributed sources captured for a suggestion request.
public struct SuggestionRequest: Equatable, Sendable {
    public init(target: SuggestionTarget, sources: [SuggestionSource]) { self.target = target; self.sources = sources }
    public var association: ContextAssociation = .scoped
    public var target: SuggestionTarget
    public var sources: [SuggestionSource]
}
