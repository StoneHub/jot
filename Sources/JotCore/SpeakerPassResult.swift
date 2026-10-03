import Foundation
import SQLite3

/// What the offline speaker pass found in one session: who spoke when, and one voice embedding per speaker.
public struct SpeakerPassResult: Sendable {
    public var segments: [(speaker: String, start: Double, end: Double)]
    public var speakers: [String: [Float]]
    public var durationSeconds: Double
    public var processingSeconds: Double
    public init(segments: [(speaker: String, start: Double, end: Double)], speakers: [String: [Float]], durationSeconds: Double, processingSeconds: Double) {
        self.segments = segments; self.speakers = speakers; self.durationSeconds = durationSeconds; self.processingSeconds = processingSeconds
    }
}
