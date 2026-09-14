/// UserDefaults keys. Existing installs store these names on disk, and the preference migration list in scripts/build-install.py must match.
public enum JotDefaultsKey {
    public static let fnRequested = "fnRequested"
    public static let highlightTargetField = "highlightTargetField"
    public static let muteSpeakersDuringDictation = "muteSpeakersDuringDictation"
    public static let selectedInputUID = "selectedInputUID"
    public static let selectedInputName = "selectedInputName"
    public static let transcriptionTuning = "transcriptionTuning"
    public static let modelUpdateChecks = "modelUpdateChecks"
    public static let modelsPrepared = "modelsPrepared"
    public static let servicePaused = "servicePaused"
    public static let historyTextView = "historyTextView"
    public static let dictationShortcut = "dictationShortcut"
    public static let personalVocabulary = "personalVocabulary"
}
