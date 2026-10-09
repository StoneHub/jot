import Foundation

/// A variant's transcript against the caption file: the recognized words and the cleaned text, each scored on its own,
/// and its speakers when the captions name them.
public struct LabScore: Codable, Sendable, Equatable {
    public var raw: WordErrorRate.Score
    public var cleaned: WordErrorRate.Score
    /// The live diarizer's speakers under the variant's grouping, before any speaker pass; nil when the captions name no speakers.
    public var liveSpeakers: LabSpeakerScore?
    /// The speaker pass's, on the rows it stores; nil also when the pass found no speech.
    public var passSpeakers: LabSpeakerScore?

    public init(raw: WordErrorRate.Score, cleaned: WordErrorRate.Score, liveSpeakers: LabSpeakerScore? = nil, passSpeakers: LabSpeakerScore? = nil) {
        self.raw = raw; self.cleaned = cleaned; self.liveSpeakers = liveSpeakers; self.passSpeakers = passSpeakers
    }

    /// Rows in time order; a row with no cleaned text counts its recognized words as cleaned.
    public init(rows: [LabRow], captions: [LabCaptions.Cue]) {
        let reference = captions.map(\.text).joined(separator: " ")
        raw = WordErrorRate.score(reference: reference, hypothesis: rows.map(\.rawText).joined(separator: " "))
        cleaned = WordErrorRate.score(reference: reference, hypothesis: rows.map { $0.cleanedText ?? $0.rawText }.joined(separator: " "))
    }
}
