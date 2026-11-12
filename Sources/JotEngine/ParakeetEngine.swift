import CoreML
import FluidAudio

/// FluidAudio's Parakeet TDT v3 models on the CPU and Neural Engine: the engine Jot has always used.
public actor ParakeetEngine: RecognitionEngine {
    private var manager: AsrManager?

    public init() {}

    public func load() async throws {
        guard manager == nil else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let models = try await AsrModels.downloadAndLoad(configuration: config, version: .v3)
        let loaded = AsrManager()
        try await loaded.loadModels(models)
        manager = loaded
    }

    public func unload() async { manager = nil }

    public func recognize(_ samples: [Float]) async throws -> [WordTiming] {
        guard let manager else { throw JotError.message("Prepare models before listening.") }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(Self.recognitionAudio(samples), decoderState: &state)
        guard let tokenTimings = result.tokenTimings else {
            throw JotError.message("Streaming recognition did not return word timing data.")
        }
        return buildWordTimings(from: tokenTimings)
    }

    /// The recognizer rejects audio under 0.3 seconds, which a final job can be once a boundary has reset the recognition window.
    /// Trailing silence brings it to length: word times count from the first sample, so real words keep theirs, and a word decoded
    /// in the silence falls past the plan's commit end. The VAD pads short audio itself, and the session clock uses the job's samples.
    static func recognitionAudio(_ samples: [Float]) -> [Float] {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioClock.sampleRate)
        return samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
    }
}
