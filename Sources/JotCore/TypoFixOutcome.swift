import Foundation

/// How one Fix typos press ended. Codes only: usage counters and `jot status` carry these, never field or model text.
public enum TypoFixOutcome: String, Sendable, CaseIterable {
    /// The fix was written and read back.
    case fixed
    /// The fix was sent, but the field did not read back as expected.
    case insertionUnverified
    /// A second press put the original text back.
    case undone
    /// The model found nothing to fix.
    case unchanged
    /// The model's result changed more than typos, so nothing was written.
    case rejected
    /// The field or selection had no text.
    case empty
    /// More text than one press fixes.
    case oversized
    /// No editable field had focus, or it could not be read safely.
    case unreadableField
    /// The field changed, focus moved, the user typed or a dictation began before the fix was written.
    case fieldChanged
    /// The field would not take the selection the fix replaces.
    case selectionUnavailable
    case unavailable
    case timedOut
    case failed
    /// A second press, a suggestion or a settings change ended the request.
    case cancelled
    /// Jot could not take the request right now, such as during a dictation.
    case blocked
}
