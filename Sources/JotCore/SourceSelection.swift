import Foundation

public struct SourceSelection: Equatable, Sendable {
    public struct Exclusion: Equatable, Sendable {
        public let id: String
        public let reason: ExclusionReason
    }
    /// Oldest first, as the prompt presents them.
    public var selected: [SuggestionSource]
    /// Input order.
    public var excluded: [Exclusion]

    public var references: [SourceRevision] { selected.map { SourceRevision(id: $0.id, revision: $0.revision) } }
}
