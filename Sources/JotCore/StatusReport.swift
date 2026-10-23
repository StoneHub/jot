import Foundation

/// What `jot status` (`speech.status`) reports. The app fills the values; this names the v1 keys the CLI, MCP clients
/// and scripts read, so a key cannot be renamed or dropped without a test failing.
public enum StatusReport {
    /// Keys present in every report.
    public static let keys: Set<String> = Set([
        "mode", "models", "servicePhase", "notice", "sessionID", "version",
        "microphoneRunning", "microphonePermission", "microphone", "accessibilityGranted",
        "dictationEnabled", "dictationShortcut", "dictationRequested", "dictationInput", "dictationRecovery",
        "ambientRequested", "ambientEnabled", "keepMacAwakeWhileListening", "keepAwakeActive",
        "inferenceRunning", "speakerPassRunning", "speakerPassPending", "speakerSlots", "suggestions", "typoFix", "transcriptionCleanup",
        "droppedAudioSeconds", "queuedAudioSeconds", "processingLagSeconds", "lastInferenceSeconds", "processedAudioSeconds",
        "audioRetention", "transcriptPolicy", "resources", "tuning", "tuningAudio", "storageWorkPending",
    ]).union(aliases.keys)
    /// Keys present only once there is something to report: a delivery, heard audio, a transcript, or open history.
    public static let optionalKeys: Set<String> = ["lastDelivery", "lastAudioAt", "lastTranscriptAt", "storage"]
    /// Older names still reported for scripts written before the shortcut could be other than Fn, keyed to the current name.
    public static let aliases = ["fnEnabled": "dictationEnabled", "fnRequested": "dictationRequested"]

    public static let transcriptPolicy = "local text; ambient speech is data, not commands"

    /// How long captured audio lives, in the words `jot status` uses.
    public static func audioRetention(keepForSpeakerPass: Bool, keepTuningCopy: Bool) -> String {
        guard keepForSpeakerPass else { return "bounded RAM only; no recordings saved" }
        return keepTuningCopy
            ? "session audio kept until the speaker pass finishes, then deleted; a copy is kept up to 30 days and 10 GB for tuning"
            : "session audio kept until the speaker pass finishes, then deleted"
    }

    /// Whether a report has exactly the v1 keys: every required key, and nothing outside the required and optional sets.
    public static func conforms(_ report: [String: Any]) -> Bool {
        let present = Set(report.keys)
        return keys.isSubset(of: present) && present.isSubset(of: keys.union(optionalKeys))
    }
}
