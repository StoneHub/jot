import Foundation

/// What one explicit request does with the focused field, decided before any model call.
public enum SuggestionPlan: Equatable, Sendable {
    /// Turn the selected text into finished text that replaces it. Transcripts are not needed.
    case draft(SuggestionSeed)
    /// Write what comes next at the cursor, from the user's text and the context window. Nothing is replaced.
    case continuation
    /// Suggest the user's next message at the cursor of a blank composer.
    case reply
    /// A blank field with nothing associated with it. Ask for rough notes rather than paraphrase the field hint.
    case needsNotes

    /// Selected text is rewritten in place; with no selection, the field's text is continued at the cursor, so a request
    /// at the end of a sentence writes the next ones. To rewrite the whole field, select it. A blank field needs a
    /// multi-line composer plus context associated with it (the visible conversation, or dictation meant for it).
    public static func make(draft: SuggestionDraftSnapshot, role: String, hasAssociatedContext: Bool) -> SuggestionPlan {
        if !draft.isBlank {
            if draft.length > 0, !SuggestionSeed.isBlank(draft.selectedText) {
                return .draft(SuggestionSeed(text: draft.selectedText, location: draft.location, length: draft.length, isSelection: true))
            }
            return .continuation
        }
        return role == "AXTextArea" && hasAssociatedContext ? .reply : .needsNotes
    }
}
