import Foundation

public struct PerformanceJob: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case dictation, ambient }
    public enum Outcome: String, Codable, Sendable { case completed, noSpeech, fillerOnly, cancelled, failed, deliveryUnverified }
    public var elapsedSeconds: Double
    public var mode: Mode
    public var outcome: Outcome
    /// For dictation, how long the key was held.
    public var audioSeconds: Double
    /// For dictation, from release until recognition of the held range finished.
    public var queueWaitSeconds: Double
    public var inferenceSeconds: Double?
    /// Dictation cleanup time; nil when cleanup did not run.
    public var cleanupSeconds: Double?
    /// The cleanup outcome (a `CleanupResult.Outcome` name, never text); nil when cleanup did not run.
    public var cleanupOutcome: String?
    public var deliverySeconds: Double?
    /// From submission (Fn release for dictation) to completion, including delivery.
    public var completionSeconds: Double
    /// For ambient recognition, the voice detector's highest speech probability over the window, to tune the speech gate against; nil when it did not run.
    public var speechProbability: Double?
    public init(elapsedSeconds: Double, mode: Mode, outcome: Outcome, audioSeconds: Double, queueWaitSeconds: Double,
                inferenceSeconds: Double?, completionSeconds: Double, cleanupSeconds: Double? = nil, deliverySeconds: Double? = nil,
                cleanupOutcome: String? = nil, speechProbability: Double? = nil) {
        self.elapsedSeconds = elapsedSeconds; self.mode = mode; self.outcome = outcome; self.audioSeconds = audioSeconds
        self.queueWaitSeconds = queueWaitSeconds; self.inferenceSeconds = inferenceSeconds; self.completionSeconds = completionSeconds
        self.cleanupSeconds = cleanupSeconds; self.deliverySeconds = deliverySeconds; self.cleanupOutcome = cleanupOutcome
        self.speechProbability = speechProbability
    }
}
