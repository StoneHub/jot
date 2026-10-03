import Foundation

public enum AgentContextError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
