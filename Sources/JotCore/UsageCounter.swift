import Foundation

/// One local usage counter, kept as a count per local day. Every name is built from these cases and the fixed outcome
/// enums they carry, so no transcript, field, app or model text can reach the table. Nothing here leaves the Mac.
public enum UsageCounter: Sendable, Hashable {
    /// How a released dictation hold ended. Together they count every hold, independent of later deletion.
    case dictation(PerformanceJob.Outcome)
    /// How a hold's text reached its field, or that it did not.
    case insertion(Insertion)
    /// Dictation cleanup's result for one hold that went through it.
    case dictationCleanup(CleanupResult.Outcome)
    /// A live phrase's cleanup: applied to the saved text, or left as recognized.
    case liveCleanup(applied: Bool)
    /// Review saved dictation showed a saved hold.
    case savedDictationReviewed
    /// The saved text was copied from that review.
    case savedDictationCopied
    case suggestionRequested
    /// A suggestion request's final outcome, counted once when its receipt completes.
    case suggestionOutcome(SuggestionHistoryEntry.Outcome)
    /// What ended a shown suggestion, counted once when its receipt completes.
    case suggestionAction(SuggestionHistoryEntry.Action)

    public enum Insertion: String, Sendable {
        case accessibility, unicode, clipboard, unverified, failed
    }

    /// A delivery result's path and verification as a counter. A verified path this build does not name counts as
    /// accessibility, the first path every delivery tries.
    public static func delivery(verified: Bool, path: String) -> UsageCounter {
        guard verified else { return .insertion(.unverified) }
        switch path {
        case "unicode_hid": return .insertion(.unicode)
        case "clipboard_hid": return .insertion(.clipboard)
        default: return .insertion(.accessibility)
        }
    }

    public var name: String {
        switch self {
        case .dictation(let outcome): return "dictation.\(outcome.rawValue)"
        case .insertion(let insertion): return "insertion.\(insertion.rawValue)"
        case .dictationCleanup(let outcome): return "cleanup.dictation.\(outcome.rawValue)"
        case .liveCleanup(let applied): return applied ? "cleanup.live.applied" : "cleanup.live.bypassed"
        case .savedDictationReviewed: return "savedDictation.reviewed"
        case .savedDictationCopied: return "savedDictation.copied"
        case .suggestionRequested: return "suggestion.requested"
        case .suggestionOutcome(let outcome): return "suggestion.outcome.\(outcome.rawValue)"
        case .suggestionAction(let action): return "suggestion.action.\(action.rawValue)"
        }
    }
}
