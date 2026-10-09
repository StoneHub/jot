import Foundation

/// One row of a lab variant's transcript, as the app would show it after the speaker pass.
public struct LabRow: Codable, Sendable, Equatable {
    public enum Cleanup: String, Codable, Sendable {
        /// Cleanup rewrote the row.
        case changed
        /// Cleanup returned the row's words as they were, ignoring case and punctuation.
        case unchanged
        /// Cleanup removed everything, such as a row of only filler.
        case removed
        /// The row has no cleaned text. Cleanup was off or unavailable, failed, or returned the phrase's words exactly as they
        /// were, which the app does not save; the run's phrase outcomes tell these apart.
        case noCleanedText = "no cleaned text"
    }

    public var start: Double
    public var end: Double
    /// The speaker most of the row's words had from the live diarizer under this variant's grouping.
    public var liveSpeaker: String?
    /// The speaker the offline pass gave the row; nil when the pass found no speech or did not run.
    public var passSpeaker: String?
    public var rawText: String
    public var cleanedText: String?
    public var cleanup: Cleanup

    public init(start: Double, end: Double, liveSpeaker: String?, passSpeaker: String?, rawText: String, cleanedText: String?, cleanup: Cleanup) {
        self.start = start; self.end = end; self.liveSpeaker = liveSpeaker; self.passSpeaker = passSpeaker
        self.rawText = rawText; self.cleanedText = cleanedText; self.cleanup = cleanup
    }
}
