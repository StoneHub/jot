import Foundation

/// The experiment's proposed bounds from docs/CONTEXTUAL-SUGGESTIONS.md; tunable, not architecture.
public struct SelectionLimits: Equatable, Sendable {
    public init(maximumSources: Int = 6, maximumSourceBytes: Int = 4096) {
        self.maximumSources = maximumSources; self.maximumSourceBytes = maximumSourceBytes
    }
    public var maximumSources = 6
    public var maximumSourceBytes = 4096
    public static let experiment = SelectionLimits()
}

extension SelectionLimits {
    /// Ten minutes of speech and agent messages come as many short pieces. Still inside the on-device context window;
    /// the selector keeps the newest when the bound forces a choice.
    public static let window = SelectionLimits(maximumSources: 12, maximumSourceBytes: 6000)
}
