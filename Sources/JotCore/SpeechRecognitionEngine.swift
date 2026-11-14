/// Local speech-to-text engines supported by Jot's live inference pipeline.
/// These stable raw values are stored in JotSettings and exposed through the CLI.
/// Adding another engine does not change existing user preferences.
public enum SpeechRecognitionEngine: Int, CaseIterable, Identifiable, Sendable {
    case parakeetV3 = 0
    case parakeetV2 = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .parakeetV3: return "Parakeet v3 (default)"
        case .parakeetV2: return "Parakeet v2"
        }
    }
}
