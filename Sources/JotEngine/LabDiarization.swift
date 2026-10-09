import FluidAudio
import JotCore

/// The lab's diarization error rate: FluidAudio's frame-wise `DiarizationDER` on its 10 ms grid, with the caption speakers
/// as the reference and a variant's stored rows as the hypothesis. FluidAudio stays inside JotEngine.
public enum LabDiarization {
    /// Nil when a cue names no single speaker.
    public static func error(captions: [LabCaptions.Cue], rows: [LabRow], speaker: (LabRow) -> String?) -> LabSpeakerScore.DiarizationError? {
        guard let reference = LabSpeakerScore.segments(captions) else { return nil }
        func segments(_ parts: [(speaker: String, start: Double, end: Double)]) -> [DERSpeakerSegment] {
            parts.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) }
        }
        let result = DiarizationDER.compute(ref: segments(reference), hyp: segments(LabSpeakerScore.segments(rows, speaker: speaker)),
            collar: LabSpeakerScore.DiarizationError.collarSeconds)
        return .init(missedSeconds: result.miss, falseAlarmSeconds: result.falseAlarm, confusionSeconds: result.confusion,
            speechSeconds: result.totalRefSpeech)
    }
}
