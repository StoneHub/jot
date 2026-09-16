import CoreML
import FluidAudio
import Foundation
import JotCore

/// The offline speaker pass: pyannote segmentation, WeSpeaker embeddings, and VBx clustering over a whole session. Its own actor, so a pass over a two-hour file never holds up live inference.
actor SpeakerPass {
    private var manager: OfflineDiarizerManager?

    /// Downloads the models once, then loads them from the same FluidAudio cache as the live models.
    func prepare() async throws { _ = try await loadedManager() }

    func unload() { manager = nil }

    /// Reads a session file straight from disk and deletes it whatever happens. A silent session is a result with no speakers, not an error.
    func run(url: URL) async throws -> SpeakerPassResult {
        defer { try? FileManager.default.removeItem(at: url) }
        // A pass queued by an automatic pause can start after Pause released the models; it loads them again and lets go of them when done.
        let loadedForThisPass = manager == nil
        let manager = try await loadedManager()
        defer { if loadedForThisPass, self.manager === manager { self.manager = nil } }
        let source = try MappedFloat32Source(url: url)
        let durationSeconds = AudioClock.seconds(samples: source.sampleCount)
        let began = Date()
        do {
            let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
            var speakers = result.speakerDatabase ?? [:]
            for segment in result.segments where speakers[segment.speakerId] == nil { speakers[segment.speakerId] = segment.embedding }
            return SpeakerPassResult(segments: result.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) },
                speakers: speakers, durationSeconds: durationSeconds, processingSeconds: Date().timeIntervalSince(began))
        } catch OfflineDiarizationError.noSpeechDetected {
            return SpeakerPassResult(segments: [], speakers: [:], durationSeconds: durationSeconds, processingSeconds: Date().timeIntervalSince(began))
        }
    }

    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = OfflineDiarizerManager()
        try await loaded.prepareModels(configuration: configuration)
        manager = loaded
        return loaded
    }
}

/// A session file mapped into memory. It is already the Float32 layout FluidAudio streams for its own file input, so no converted copy is written anywhere.
struct MappedFloat32Source: AudioSampleSource {
    private let data: Data
    let sampleCount: Int

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        sampleCount = data.count / MemoryLayout<Float>.stride
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, offset >= 0, offset < sampleCount else { return }
        let available = min(sampleCount - offset, count)
        data.withUnsafeBytes { destination.update(from: $0.bindMemory(to: Float.self).baseAddress!.advanced(by: offset), count: available) }
    }
}
