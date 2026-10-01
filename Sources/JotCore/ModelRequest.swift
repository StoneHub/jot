import Foundation

/// One fresh-session model request. Jot owns the wording and bounds; AppleFM only runs it.
public struct ModelRequest: Equatable, Sendable {
    public init(instructions: String, prompt: String, maximumResponseTokens: Int) {
        self.instructions = instructions; self.prompt = prompt; self.maximumResponseTokens = maximumResponseTokens
    }
    public let instructions: String
    public let prompt: String
    public let maximumResponseTokens: Int

    /// SHA-256 of the instructions, a blank line and the prompt.
    public var sha256: String { ContentHash.sha256(instructions + "\n\n" + prompt) }
}
