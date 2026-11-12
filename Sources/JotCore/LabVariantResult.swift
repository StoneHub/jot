import Foundation

/// One variant's output from a lab run.
public struct LabVariantResult: Codable, Sendable, Equatable {
    public struct Timings: Codable, Sendable, Equatable {
        public var audioSeconds: Double
        /// Feeding the audio through capture, recognition and cleanup; shared by the variants of one recognition run.
        public var recognitionSeconds: Double
        /// The offline speaker pass over the same audio; shared too.
        public var speakerPassSeconds: Double
        /// Process CPU time (user and system) the recognition run took; shared by its variants. Neural Engine time is not CPU.
        public var cpuSeconds: Double
        /// The same for the speaker pass.
        public var speakerPassCPUSeconds: Double

        public init(audioSeconds: Double, recognitionSeconds: Double, speakerPassSeconds: Double, cpuSeconds: Double = 0, speakerPassCPUSeconds: Double = 0) {
            self.audioSeconds = audioSeconds; self.recognitionSeconds = recognitionSeconds; self.speakerPassSeconds = speakerPassSeconds
            self.cpuSeconds = cpuSeconds; self.speakerPassCPUSeconds = speakerPassCPUSeconds
        }

        /// Older `variants.json` files have no CPU figures.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
            recognitionSeconds = try container.decode(Double.self, forKey: .recognitionSeconds)
            speakerPassSeconds = try container.decode(Double.self, forKey: .speakerPassSeconds)
            cpuSeconds = try container.decodeIfPresent(Double.self, forKey: .cpuSeconds) ?? 0
            speakerPassCPUSeconds = try container.decodeIfPresent(Double.self, forKey: .speakerPassCPUSeconds) ?? 0
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
