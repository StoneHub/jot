import Foundation

/// One variant's output from a lab run.
public struct LabVariantResult: Codable, Sendable, Equatable {
    public struct Timings: Codable, Sendable, Equatable {
        public var audioSeconds: Double
        /// Feeding the audio through capture, recognition and cleanup; shared by the variants of one recognition run.
        public var recognitionSeconds: Double
        /// The offline speaker pass over the same audio; shared too.
        public var speakerPassSeconds: Double

        public init(audioSeconds: Double, recognitionSeconds: Double, speakerPassSeconds: Double) {
            self.audioSeconds = audioSeconds; self.recognitionSeconds = recognitionSeconds; self.speakerPassSeconds = speakerPassSeconds
        }
    }

    public var name: String
    public var settings: [String: LabVariant.Value]
    /// Variants with the same number share one recognition run.
    public var recognitionRun: Int
    /// The stored rows after the speaker pass, as `jot export --json` would list them.
    public var rows: [LabRow]
    /// The same rows joined into the paragraphs Sessions shows at this variant's paragraph pause.
    public var paragraphs: [LabRow]
    public var timings: Timings
    public var score: LabScore?
    /// What cleanup did with each phrase of the run, by outcome (changed, unchanged, modelError…); empty when cleanup was off.
    public var cleanupOutcomes: [String: Int]

    public init(name: String, settings: [String: LabVariant.Value], recognitionRun: Int, rows: [LabRow], paragraphs: [LabRow] = [],
                timings: Timings, score: LabScore?, cleanupOutcomes: [String: Int] = [:]) {
        self.name = name; self.settings = settings; self.recognitionRun = recognitionRun
        self.rows = rows; self.paragraphs = paragraphs; self.timings = timings; self.score = score; self.cleanupOutcomes = cleanupOutcomes
    }
}
