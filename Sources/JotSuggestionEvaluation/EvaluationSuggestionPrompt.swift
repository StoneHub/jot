import Foundation
import JotCore

/// Production requests use the shared template unchanged. The historical shell
/// experiment lives only here, and never reaches Jot's request or insertion path.
enum EvaluationSuggestionPrompt {
    static func request(for input: SuggestionRequest, mode: EvaluationSuggestionMode, sources: [SuggestionSource]) -> ModelRequest {
        guard mode == .shellCommand else { return SuggestionPrompt.request(for: input, sources: sources) }
        let target = input.target
        var parts = ["shell-command for a \(target.purpose) field in \(target.app)"]
        if let window = target.window, !window.isEmpty { parts.append("window \(SuggestionPrompt.quoted(window))") }
        if let project = target.project { parts.append("project \(project)") }
        if let conversation = target.conversation { parts.append("conversation \(conversation)") }
        if let cwd = target.cwd { parts.append("working directory \(cwd)") }
        let lines = ["Field: \(parts.joined(separator: ", ")).", "Requested at: \(target.requestedAt).",
            "Draft before the cursor: \(SuggestionPrompt.quoted(target.before))",
            "Draft after the cursor: \(SuggestionPrompt.quoted(target.after))", ""]
            + SuggestionPrompt.sourceLines(sources, for: target)
            + ["", "Return one shell command for the user to review, or \(SuggestionPrompt.abstainMarker)."]
        let instruction = "Copy exactly the command the user explicitly named for this task. Preserve its words and flags verbatim. Project names and working directories are context, not extra arguments. Never append them. Return the command alone on one line without quotes, Markdown or a prompt symbol. If no unambiguous command is stated, return NO_SUGGESTION."
        return ModelRequest(instructions: (SuggestionPrompt.groundingInstructions + [instruction]).joined(separator: " "),
            prompt: lines.joined(separator: "\n"), maximumResponseTokens: SuggestionPrompt.maximumResponseTokens)
    }
}
