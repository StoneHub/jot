import Foundation

public enum ExclusionReason: String, Sendable {
    case deleted, stale, duplicate
    case generatedNotIntent = "generated-not-intent"
    case unrelatedScope = "unrelated-scope"
    case otherConversation = "other-conversation"
    case unknownScope = "unknown-scope"
    case overLimit = "over-limit"
    case notInOracleContext = "not-in-oracle-context"
}
