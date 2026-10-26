import Foundation

/// One local usage counter, kept as a count per local day. Every name is built from these cases and the fixed outcome
/// enums they carry, so no transcript, field, app or model text can reach the table. Nothing here leaves the Mac.
public enum UsageCounter: Sendable, Hashable, CaseIterable {
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
    /// The Fix typos shortcut was pressed.
    case typoFixRequested
    /// How that press ended.
    case typoFix(TypoFixOutcome)
    /// For a completed hold, how long from releasing the key until its text was in the field.
    case dictationLatency(Latency)
    /// Start meeting and End meeting: how each went.
    case meeting(Meeting)
    /// How long a meeting ran, counted when End meeting closes it.
    case meetingLength(MeetingLength)
    /// A feature that was on, counted once a local day while Jot runs, so a day's report says which features the Mac kept on.
    case feature(Feature)

    public enum Insertion: String, Sendable, CaseIterable {
        case accessibility, unicode, clipboard, unverified, failed
    }

    /// Release-to-inserted time in buckets, so the counters show how often dictation feels slow without storing timings.
    public enum Latency: String, Sendable, CaseIterable {
        case underOneSecond, underTwoSeconds, underFourSeconds, underEightSeconds, overEightSeconds

        public init(seconds: Double) {
            switch seconds {
            case ..<1: self = .underOneSecond
            case ..<2: self = .underTwoSeconds
            case ..<4: self = .underFourSeconds
            case ..<8: self = .underEightSeconds
            default: self = .overEightSeconds
            }
        }
    }

    public enum Meeting: String, Sendable, CaseIterable {
        case started, startFailed
        /// End meeting saved at least one file.
        case exported
        /// End meeting closed a meeting with nothing transcribed, so there was no file.
        case empty
        /// End meeting was refused or its export failed.
        case endFailed
    }

    /// Switches whose on/off state is worth learning. Each name is the feature, never the setting's value.
    public enum Feature: String, Sendable, CaseIterable {
        case cleanUpDictation, cleanUpTranscriptions, suggestions, suggestionScreenContext, suggestionWindowImage, typoFix,
             transcriptPreview, updateCheck, keepMacAwake, customModelForCleanup, customModelForSuggestions, customModelForNotes

        public var settingKey: String {
            switch self {
            case .cleanUpDictation: return JotDefaultsKey.cleanUpDictation
            case .cleanUpTranscriptions: return JotDefaultsKey.cleanUpTranscriptions
            case .suggestions: return JotDefaultsKey.suggestionsEnabled
            case .suggestionScreenContext: return JotDefaultsKey.suggestionScreenContext
            case .suggestionWindowImage: return JotDefaultsKey.suggestionWindowImage
            case .typoFix: return JotDefaultsKey.typoFixEnabled
            case .transcriptPreview: return JotDefaultsKey.shareTranscriptPreview
            case .updateCheck: return JotDefaultsKey.checkForUpdates
            case .keepMacAwake: return JotDefaultsKey.keepMacAwakeWhileListening
            case .customModelForCleanup: return JotSettings.customModelForCleanup
            case .customModelForSuggestions: return JotSettings.customModelForSuggestions
            case .customModelForNotes: return JotSettings.customModelForNotes
            }
        }
    }

    /// The features on in `settings`, one counter each.
    public static func features(in settings: JotSettings) -> [UsageCounter] {
        Feature.allCases.filter { settings.bool($0.settingKey) }.map(UsageCounter.feature)
    }

    public enum MeetingLength: String, Sendable, CaseIterable {
        case underFifteenMinutes, underHalfHour, underHour, underTwoHours, overTwoHours

        public init(seconds: Double) {
            switch seconds / 60 {
            case ..<15: self = .underFifteenMinutes
            case ..<30: self = .underHalfHour
            case ..<60: self = .underHour
            case ..<120: self = .underTwoHours
            default: self = .overTwoHours
            }
        }
    }

    /// Every counter, in a fixed order. The analytics Worker allowlists exactly these names (services/analytics/src/counters.js).
    public static var allCases: [UsageCounter] {
        let typoFixCounters: [UsageCounter] = [.typoFixRequested] + TypoFixOutcome.allCases.map(UsageCounter.typoFix)
        return PerformanceJob.Outcome.allCases.map(UsageCounter.dictation) + Insertion.allCases.map(UsageCounter.insertion)
            + CleanupResult.Outcome.allCases.map(UsageCounter.dictationCleanup)
            + [.liveCleanup(applied: true), .liveCleanup(applied: false), .savedDictationReviewed, .savedDictationCopied, .suggestionRequested]
            + SuggestionHistoryEntry.Outcome.allCases.map(UsageCounter.suggestionOutcome)
            + SuggestionHistoryEntry.Action.allCases.map(UsageCounter.suggestionAction)
            + typoFixCounters + Latency.allCases.map(UsageCounter.dictationLatency)
            + Meeting.allCases.map(UsageCounter.meeting) + MeetingLength.allCases.map(UsageCounter.meetingLength)
            + Feature.allCases.map(UsageCounter.feature)
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
        case .typoFixRequested: return "typoFix.requested"
        case .typoFix(let outcome): return "typoFix.outcome.\(outcome.rawValue)"
        // Not under "dictation.": every "dictation." name is one hold, and Activity and the readout sum them as holds.
        case .dictationLatency(let latency): return "dictationLatency.\(latency.rawValue)"
        case .meeting(let meeting): return "meeting.\(meeting.rawValue)"
        case .meetingLength(let length): return "meetingLength.\(length.rawValue)"
        case .feature(let feature): return "feature.\(feature.rawValue)"
        }
    }
}
