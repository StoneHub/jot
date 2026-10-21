import Foundation

public enum CleanupAvailability: String, Sendable, CaseIterable {
    case available, olderSystem, deviceNotEligible, notEnabled, modelNotReady
    /// A model outside Apple Intelligence is chosen, but its endpoint or model name is missing or unusable.
    case notConfigured
    public var explanation: String {
        switch self {
        case .available: return "Uses Apple Intelligence on this Mac to make captured speech more readable."
        case .olderSystem: return "Apple cleanup requires macOS 26 or later. Transcription works without it."
        case .deviceNotEligible: return "Apple cleanup is unavailable on this Mac. Transcription works without it."
        case .notEnabled: return "Apple Intelligence is off in macOS. Transcription works without cleanup."
        case .modelNotReady: return "Apple Intelligence is not ready. Transcription works without cleanup."
        case .notConfigured: return "The custom model needs an endpoint and a model name. Transcription works without cleanup."
        }
    }

    public var notesBlocker: String? {
        switch self {
        case .available: return nil
        case .olderSystem: return "Session notes require macOS 26 or later, or a custom model for notes."
        case .deviceNotEligible: return "Apple Intelligence is unavailable on this Mac. Switch notes to a custom model in Settings to write them."
        case .notEnabled: return "Apple Intelligence is off in macOS. Turn it on, or switch notes to a custom model in Settings."
        case .modelNotReady: return "Apple Intelligence is not ready. Try again later."
        case .notConfigured: return "The custom model needs an endpoint and a model name before it can write notes."
        }
    }

    public var suggestionBlocker: String? {
        switch self {
        case .available: return nil
        case .olderSystem: return "Suggestions require macOS 26 or later. Dictation and saved text still work."
        case .deviceNotEligible: return "Suggestions are unavailable on this Mac. Dictation and saved text still work."
        case .notEnabled: return "Apple Intelligence is off in macOS. Dictation and saved text still work."
        case .modelNotReady: return "Apple Intelligence is not ready. Dictation and saved text still work."
        case .notConfigured: return "The custom model needs an endpoint and a model name. Dictation and saved text still work."
        }
    }
}
