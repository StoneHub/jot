import Foundation

/// The four grouping and speaker values. The initializer holds each default and the ranges below bound it; `JotSettings`
/// reads both from here, so a default or a range exists once.
public struct TranscriptionTuning: Codable, Sendable, Equatable {
    public static let speakerConfidenceRange = 0.45...0.9
    public static let minimumSpeakerTurnRange = 0.2...2.0
    public static let paragraphPauseRange = 0.3...2.5
    public var speakerConfidence: Double = 0.65
    public var minimumSpeakerTurn: Double = 1.2
    public var paragraphPause: Double = 1.5
    public var hideFillerRows = true
    public init() {}
    public static var steady: Self {
        var value = Self(); value.speakerConfidence = 0.75; value.minimumSpeakerTurn = 1.2; value.paragraphPause = 1.5
        return value
    }
    public static var detailed: Self {
        var value = Self(); value.speakerConfidence = 0.5; value.minimumSpeakerTurn = 0.2; value.paragraphPause = 0.5; value.hideFillerRows = false
        return value
    }
    /// Each value inside its range; a value that is not a number becomes the default.
    public var bounded: Self {
        let defaults = Self()
        var result = self
        result.speakerConfidence = Self.clamp(speakerConfidence, to: Self.speakerConfidenceRange, or: defaults.speakerConfidence)
        result.minimumSpeakerTurn = Self.clamp(minimumSpeakerTurn, to: Self.minimumSpeakerTurnRange, or: defaults.minimumSpeakerTurn)
        result.paragraphPause = Self.clamp(paragraphPause, to: Self.paragraphPauseRange, or: defaults.paragraphPause)
        return result
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, or fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
