import Foundation

public struct CleanupResult: Sendable {
    public enum Outcome: String, Sendable {
        case changed, unchanged, busy, cancelled, empty, oversized, unavailable
        case invalidCount, rejectedEdits, modelError, timedOut
    }
    public let texts: [String]
    public let outcome: Outcome
}
