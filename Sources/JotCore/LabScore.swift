import Foundation

/// A variant's transcript against the caption file: the recognized words and the cleaned text, each scored on its own.
public struct LabScore: Codable, Sendable, Equatable {
    public var raw: WordErrorRate.Score
    public var cleaned: WordErrorRate.Score

    public init(raw: WordErrorRate.Score, cleaned: WordErrorRate.Score) { self.raw = raw; self.cleaned = cleaned }

    /// Rows in time order; a row with no cleaned text counts its recognized words as cleaned.
    public init(rows: [LabRow], captions: [LabCaptions.Cue]) {
        let reference = captions.map(\.text).joined(separator: " ")
        raw = WordErrorRate.score(reference: reference, hypothesis: rows.map(\.rawText).joined(separator: " "))
        cleaned = WordErrorRate.score(reference: reference, hypothesis: rows.map { $0.cleanedText ?? $0.rawText }.joined(separator: " "))
    }
}
