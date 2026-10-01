import Foundation

public enum SuggestionMode: String, Decodable, CaseIterable, Sendable {
    case reply, continuation
    case shellCommand = "shell-command"
    /// Turn the user's rough notes (`SuggestionTarget.seed`) into finished text that replaces them.
    case draft
}
