import Foundation

/// A sleep interruption resumes only the listening session that sleep interrupted.
public struct SleepResumePolicy: Sendable {
    private var sleeping = false
    private var pending = false
    public init() {}
    public mutating func willSleep(ambientRunning: Bool) {
        guard !sleeping else { return }
        sleeping = true
        pending = ambientRunning
    }
    public mutating func didWake() { sleeping = false }
    public mutating func cancel() { pending = false }
    /// `paused`: the microphone is off and neither a pause nor a start is under way. The models may still be loaded.
    public mutating func takeResume(paused: Bool) -> Bool {
        guard pending, !sleeping, paused else { return false }
        pending = false
        return true
    }
}
