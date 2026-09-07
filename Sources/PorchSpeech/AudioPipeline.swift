import Foundation
import AVFoundation
import CoreML
import FluidAudio
import PorchCore

struct AudioJob: Sendable {
    let sessionID: String
    let startedAt: Date
    let offset: Double
    let samples: [Float]
    let mode: String
    let ticket: UUID
}

struct SpeechOutput: Sendable {
    let transcripts: [Transcript]
    let text: String
    let processingSeconds: Double
}

/// One inference worker. The controller never submits overlapping jobs.
actor SpeechPipeline {
    private var asr: AsrManager?
    private var vad: VadManager?
    private var diarizer: SortformerDiarizer?
    private var sessionID = ""
    private var expectedOffset: Double = 0
    private var baseOffset: Double = 0
    private var probabilities: [Int: [Float]] = [:]

    func prepare() async throws {
        if asr == nil {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.downloadAndLoad(configuration: config, version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            asr = manager
        }
        if vad == nil { vad = try await VadManager() }
        if diarizer == nil {
            let config = SortformerConfig.default
            let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .cpuAndNeuralEngine)
            var timeline = DiarizerTimelineConfig.sortformerDefault
            timeline.maxStoredFrames = 1000
            timeline.storeSegments = false
            let manager = SortformerDiarizer(config: config, timelineConfig: timeline)
            manager.initialize(models: models)
            diarizer = manager
        }
    }

    func testFile(_ url: URL) async throws -> SpeechOutput {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw PorchError.message("Diagnostic files must be at most 60 seconds.") }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await infer(AudioJob(sessionID: UUID().uuidString, startedAt: Date(), offset: 0, samples: samples, mode: "ambient", ticket: UUID()))
    }

    func infer(_ job: AudioJob) async throws -> SpeechOutput {
        guard let asr, let vad, let diarizer else { throw PorchError.message("Prepare models before listening.") }
        let begin = Date()
        if job.mode == "ambient" {
            if sessionID != job.sessionID || abs(job.offset - expectedOffset) > 0.02 {
                diarizer.reset(); probabilities.removeAll(); sessionID = job.sessionID; baseOffset = job.offset
            }
            expectedOffset = job.offset + Double(job.samples.count) / 16000
            diarizer.addAudio(job.samples)
            while let update = try diarizer.process() {
                let chunk = update.chunkResult
                for frame in 0..<chunk.finalizedFrameCount {
                    probabilities[chunk.startFrame + frame] = (0..<4).map { chunk.probability(speaker: $0, frame: frame, numSpeakers: 4) }
                }
                for frame in 0..<chunk.tentativeFrameCount {
                    probabilities[chunk.tentativeStartFrame + frame] = (0..<4).map { chunk.tentativeProbability(speaker: $0, frame: frame, numSpeakers: 4) }
                }
            }
            let keepFrom = Int((job.offset - baseOffset - 2) / 0.08)
            probabilities = probabilities.filter { $0.key >= keepFrom }
        }
        // Conservative neural speech gate; uncertain speaker attribution does not suppress ASR.
        let activity = try await vad.process(job.samples)
        guard activity.contains(where: { $0.probability >= 0.20 }) else {
            return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin))
        }
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(job.samples, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin)) }
        var segments: [Transcript] = []
        if job.mode == "ambient", let timings = result.tokenTimings, !timings.isEmpty {
            let words = buildWordTimings(from: timings)
            var group: [WordTiming] = []
            var currentSpeaker: String?
            func appendGroup() {
                guard let first = group.first, let last = group.last else { return }
                segments.append(Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + first.startTime, endSeconds: job.offset + last.endTime,
                    text: group.map(\.word).joined(separator: " "), speakerID: currentSpeaker, mode: job.mode))
            }
            for word in words {
                let frame = Int((job.offset - baseOffset + (word.startTime + word.endTime) / 2) / 0.08)
                let values = probabilities[frame] ?? []
                let active = values.enumerated().filter { $0.element >= 0.5 }
                let speaker: String? = active.count == 1 ? "speaker-\(active[0].offset + 1)" : (active.count > 1 ? "overlap" : nil)
                if !group.isEmpty && speaker != currentSpeaker { appendGroup(); group = [] }
                currentSpeaker = speaker; group.append(word)
            }
            appendGroup()
        }
        if segments.isEmpty {
            segments = [Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                endSeconds: job.offset + Double(job.samples.count) / 16000, text: text, speakerID: nil, mode: job.mode)]
        }
        return SpeechOutput(transcripts: segments, text: text, processingSeconds: Date().timeIntervalSince(begin))
    }
}

enum PorchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Audio callback owns resampling; only a bounded 8-second RAM queue crosses to the controller.
final class MicrophoneCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let callbacks = DispatchGroup()
    private var pending: [Float] = []
    private var tapInstalled = false
    private var dropped = 0
    private var lastAudio = Date.distantPast
    private var rms: Float = 0
    var running: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false; callbacks.wait() }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw PorchError.message("No usable microphone input. Check the macOS input device.")
        }
        lock.lock(); pending.removeAll(); dropped = 0; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            self.callbacks.enter()
            defer { self.callbacks.leave() }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            self.accept(samples)
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { input.removeTap(onBus: 0); tapInstalled = false; throw error }
    }

    private func accept(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        lastAudio = Date()
        rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        pending.append(contentsOf: samples)
        if pending.count > 128000 { let excess = pending.count - 128000; pending.removeFirst(excess); dropped += excess }
    }

    func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, dropped, lastAudio, rms)
        pending = []; dropped = 0
        return result
    }

    func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        callbacks.wait()
    }
}
