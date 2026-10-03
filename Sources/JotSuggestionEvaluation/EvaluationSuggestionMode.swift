import JotCore

enum EvaluationSuggestionMode: String, Decodable, CaseIterable, Sendable {
    case reply, continuation, draft
    case shellCommand = "shell-command"

    var production: SuggestionMode? { SuggestionMode(rawValue: rawValue) }
}
