import Foundation

/// Presentation processing of a model response. Callers keep the verbatim response separately.
public enum ProcessedOutput: Equatable, Sendable {
    case suggestion(String)
    case abstained(String)
    case rejected(String)
}
