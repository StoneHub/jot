import Foundation

/// The named starting points above the tuning sliders.
public enum TuningPreset: String, CaseIterable, Sendable {
    case balanced, steady, detailed
    public var title: String {
        switch self {
        case .balanced: "Balanced"
        case .steady: "Steadier speakers"
        case .detailed: "More detail"
        }
    }
    public var tuning: TranscriptionTuning {
        switch self {
        case .balanced: .init()
        case .steady: .steady
        case .detailed: .detailed
        }
    }
    /// The preset these values equal, allowing for the rounding a stepped slider adds; nil when they are custom.
    public static func matching(_ tuning: TranscriptionTuning) -> TuningPreset? {
        allCases.first { preset in
            let values = preset.tuning
            return abs(values.speakerConfidence - tuning.speakerConfidence) < 0.001
                && abs(values.minimumSpeakerTurn - tuning.minimumSpeakerTurn) < 0.001
                && abs(values.paragraphPause - tuning.paragraphPause) < 0.001
                && values.hideFillerRows == tuning.hideFillerRows
        }
    }
}
