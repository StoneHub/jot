import JotCore

/// Shell-specific output constraints belong to the corpus experiment only.
enum EvaluationSuggestionOutput {
    static func process(_ raw: String, mode: EvaluationSuggestionMode) -> ProcessedOutput {
        if let production = mode.production { return SuggestionOutput.process(raw, mode: production) }
        let result = SuggestionOutput.process(raw, mode: .reply)
        // Shell historically rejects any newline before the paragraph check.
        if case .suggestion(let text) = result, text.contains("\n") { return .rejected("multiline-shell-command") }
        if result == .rejected("multiple-paragraphs") { return .rejected("multiline-shell-command") }
        return result
    }
}
