import Foundation

public enum CleanupAvailability: String, Sendable, CaseIterable {
    case available, olderSystem, deviceNotEligible, notEnabled, modelNotReady
    public var explanation: String {
        switch self {
        case .available: return "Uses Apple Intelligence on this Mac to make captured speech more readable."
        case .olderSystem: return "Apple cleanup requires macOS 26 or later. Transcription works without it."
        case .deviceNotEligible: return "Apple cleanup is unavailable on this Mac. Transcription works without it."
        case .notEnabled: return "Apple Intelligence is off in macOS. Transcription works without cleanup."
        case .modelNotReady: return "Apple Intelligence is not ready. Transcription works without cleanup."
        }
    }

    public var suggestionBlocker: String? {
        switch self {
        case .available: return nil
        case .olderSystem: return "Suggestions require macOS 26 or later. Dictation and saved text still work."
        case .deviceNotEligible: return "Suggestions are unavailable on this Mac. Dictation and saved text still work."
        case .notEnabled: return "Apple Intelligence is off in macOS. Dictation and saved text still work."
        case .modelNotReady: return "Apple Intelligence is not ready. Dictation and saved text still work."
        }
    }
}
