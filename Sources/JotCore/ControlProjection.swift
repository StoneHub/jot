import Foundation

/// What the socket's control surfaces report, worked out from plain values the service hands over,
/// so the package can test the projection without the app.
public enum ControlProjection {
    /// `speech.controls`. A held dictation reads as capturing and one still being recognized as recognizing;
    /// otherwise the last attempt's state stands. `suggestion` is the suggestion coordinator's diagnostics.
    /// `version` is what the caller asked for; version 1 leaves out `meetingStartedAt` and `notice`.
    public static func controls(version: Int = 1, mode: String, meetingActive: Bool, dictationActive: Bool, dictationPending: Bool,
                                lastAttempt: DictationAttempt.State?, dictationSequence: UInt64,
                                suggestion: [String: Any], inputLevel: Double,
                                meetingStartedAt: Date? = nil, notice: ControlNotice? = nil) -> ControlSnapshot {
        let phase: DictationAttempt.State? = dictationActive ? .capturing : dictationPending ? .recognizing : lastAttempt
        return ControlSnapshot(version: version, mode: mode, meetingActive: meetingActive, dictation: phase,
                               dictationSequence: dictationSequence,
                               suggestion: suggestion["outcome"] as? String ?? "idle",
                               suggestionSequence: suggestion["requests"] as? Int ?? 0, inputLevel: inputLevel,
                               meetingStartedAt: meetingStartedAt, notice: notice)
    }
}
