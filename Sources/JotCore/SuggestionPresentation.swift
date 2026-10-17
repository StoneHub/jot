import Foundation

/// What the suggestion card shows once a request has its model result: the ready card, a notice that says why there is
/// no suggestion, or nothing. Pure, so the wording and every transition can be tested without a field or a window.
public enum SuggestionPresentation: Equatable, Sendable {
    /// `candidate` is what Tab inserts; the card shows it with spaces trimmed.
    case card(candidate: String, title: String, action: String)
    /// `reason` is a code for diagnostics and history, never field, screen or output text.
    case notice(text: String, reason: String)
    /// The request was cancelled; close the card without a notice.
    case dismiss

    public static let needsNotes = "Jot needs a few rough notes. Type or dictate them here, then double-tap Fn."

    /// The model result reviewed against the field it was made for. `before` is the text before the cursor, or before
    /// the seed for a draft; `context` is the screen excerpt the request used.
    public static func decide(_ result: ModelCallResult, mode: SuggestionMode, singleLine: Bool, draft: SuggestionDraftSnapshot,
                              before: String, seed: SuggestionSeed?, placeholder: String?, context: String?) -> SuggestionPresentation {
        switch result {
        case .output(let raw):
            switch SuggestionOutput.process(raw, mode: mode, singleLine: singleLine) {
            case .suggestion(let output):
                let text = mode == .continuation ? SuggestionOutput.continuation(output, before: before) : output
                let review = text.isEmpty ? .unchanged : SuggestionOutput.review(text, draft: draft, seed: seed?.text,
                                                                                 placeholder: placeholder, context: context)
                switch review {
                case .accept:
                    let (title, action) = labels(mode: mode, seed: seed)
                    return .card(candidate: text, title: title, action: action)
                case .unchanged:
                    return .notice(text: mode == .continuation ? "No suggestion: the result only repeated your text."
                                                               : "Your selection already reads well. No changes suggested.",
                                   reason: "unchanged")
                case .restatesHint:
                    return .notice(text: draft.isBlank ? needsNotes : "No suggestion: the result only repeated the field's hint.",
                                   reason: "restates-hint")
                case .copiesContext:
                    return .notice(text: "No suggestion: the result only repeated text on screen.", reason: "copies-context")
                }
            case .abstained(let detail), .rejected(let detail):
                switch mode {
                case .draft: return .notice(text: "No suggestion for this selection.", reason: detail)
                case .continuation: return .notice(text: "No suggestion: nothing to add from your text and this context.", reason: detail)
                case .reply: return .notice(text: "No suggestion from this context.", reason: detail)
                }
            }
        case .unavailable: return .notice(text: "No suggestion: Apple Intelligence is unavailable.", reason: "model-unavailable")
        case .timedOut: return .notice(text: "No suggestion: the model took too long.", reason: "timed-out")
        case .blocked: return .notice(text: "No suggestion: the previous request is still ending.", reason: "blocked")
        case .failed: return .notice(text: "No suggestion: the model could not complete the request.", reason: "model-failed")
        case .cancelled: return .dismiss
        }
    }

    /// A selection rewrite is grounded in its seed. Replies and continuations need external context; nil when the mode
    /// can go ahead without it.
    public static func missingContext(for mode: SuggestionMode) -> SuggestionPresentation? {
        switch mode {
        case .reply: return .notice(text: needsNotes, reason: "no-context")
        case .continuation: return .notice(text: "No suggestion: Jot has nothing from the last few minutes to continue from.",
                                           reason: "no-context")
        case .draft: return nil
        }
    }

    /// The ready card's title and the Tab hint under it.
    static func labels(mode: SuggestionMode, seed: SuggestionSeed?) -> (title: String, action: String) {
        if let seed {
            return seed.isSelection ? ("Rewrite of your selection", "Tab to replace the selection")
                                    : ("Draft from your notes", "Tab to replace your notes")
        }
        return mode == .continuation ? ("Suggested continuation", "Tab to insert at the cursor") : ("Suggested reply", "Tab to insert")
    }
}
