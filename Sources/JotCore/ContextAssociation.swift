import Foundation

public enum ContextAssociation: Equatable, Sendable {
    case scoped
    /// Applies only to the rows supplied by an explicit recent-context request. Never changes their provenance.
    case explicitRecentRequest
}
