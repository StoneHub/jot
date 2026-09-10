import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreML
import FluidAudio
import JotCore

struct AudioJob: Sendable {
    let sessionID: String
    let startedAt: Date
    let offset: Double
    let samples: [Float]
    let mode: String
    let ticket: UUID
    var submittedUptime = ProcessInfo.processInfo.systemUptime
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
    /// Last confirmed speaker of the previous ambient block, carried forward while audio stays continuous.
    private var lastSpeaker: String?

    func prepare() async throws {
        if asr == nil {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.downloadAndLoad(configuration: config, version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            asr = manager
        }
        try Task.checkCancellation()
        if vad == nil { vad = try await VadManager() }
        try Task.checkCancellation()
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

    func unload() {
        asr = nil; vad = nil; diarizer = nil; lastSpeaker = nil
        probabilities.removeAll(keepingCapacity: false)
        sessionID = ""; expectedOffset = 0; baseOffset = 0
    }

    func testFile(_ url: URL, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw JotError.message("Diagnostic files must be at most 60 seconds.") }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await infer(AudioJob(sessionID: UUID().uuidString, startedAt: Date(), offset: 0, samples: samples, mode: "ambient", ticket: UUID()), tuning: tuning)
    }

    func infer(_ job: AudioJob, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        guard let asr, let vad, let diarizer else { throw JotError.message("Prepare models before listening.") }
        try Task.checkCancellation()
        let begin = Date()
        if job.mode == "ambient" {
            if sessionID != job.sessionID || abs(job.offset - expectedOffset) > 0.02 {
                diarizer.reset(); probabilities.removeAll(); sessionID = job.sessionID; baseOffset = job.offset; lastSpeaker = nil
            }
            expectedOffset = job.offset + Double(job.samples.count) / 16000
            diarizer.addAudio(job.samples)
            while let update = try diarizer.process() {
                try Task.checkCancellation()
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
        try Task.checkCancellation()
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(job.samples, decoderState: &state)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin)) }
        var segments: [Transcript] = []
        if job.mode == "ambient", let timings = result.tokenTimings, !timings.isEmpty {
            let words = buildWordTimings(from: timings)
            let attributed = words.map { word -> AttributedWord in
                let frame = Int((job.offset - baseOffset + (word.startTime + word.endTime) / 2) / 0.08)
                return AttributedWord(text: word.word, start: word.startTime, end: word.endTime, probabilities: probabilities[frame] ?? [])
            }
            let turns = TranscriptGrouping.turns(attributed, tuning: tuning, continuing: lastSpeaker)
            if let final = turns.last?.speaker, final != "overlap" { lastSpeaker = final }
            segments = turns.map { turn in
                Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + turn.start, endSeconds: job.offset + turn.end,
                    text: turn.text, speakerID: turn.speaker, mode: job.mode)
            }
        }
        if segments.isEmpty {
            segments = [Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                endSeconds: job.offset + Double(job.samples.count) / 16000, text: text, speakerID: nil, mode: job.mode)]
        }
        return SpeechOutput(transcripts: segments, text: text, processingSeconds: Date().timeIntervalSince(begin))
    }
}

enum JotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Audio callback owns resampling; only a bounded 8-second RAM queue crosses to the controller.
struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String

    static func available() -> [Self] {
        deviceIDs().compactMap { id in
            guard hasInputStreams(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return Self(id: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultName() -> String? {
        guard let id = deviceIDProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    static func deviceID(for uid: String) -> AudioObjectID? {
        deviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid && hasInputStreams($0) }
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &result) == noErr else { return [] }
        return result
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) == noErr && byteCount > 0
    }

    private static func deviceIDProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioObjectID = 0
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, &value) == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

final class MicrophoneCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var engine = AVAudioEngine()
    private let callbacks = DispatchGroup()
    private var pending: [Float] = []
    private var tapInstalled = false
    private var dropped = 0
    private var lastAudio = Date.distantPast
    private var rms: Float = 0
    private var selectedInputUID: String?
    var running: Bool { engine.isRunning }

    func setInput(uid: String?) throws {
        guard !engine.isRunning else { throw JotError.message("Pause capture before changing the microphone.") }
        selectedInputUID = uid
    }

    func start() throws {
        guard !engine.isRunning else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false; callbacks.wait() }
        // A fresh input node follows the current system default when no explicit device is selected.
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let selectedInputUID {
            guard let selectedDevice = AudioInputDevice.deviceID(for: selectedInputUID) else {
                throw JotError.message("The selected microphone is no longer available. Choose System Default.")
            }
            guard let unit = input.audioUnit else { throw JotError.message("No usable microphone input.") }
            var device = selectedDevice
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr else {
                throw JotError.message("Jot could not select the chosen microphone.")
            }
        }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw JotError.message("No usable microphone input. Check the macOS input device.")
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

    var bufferedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }; return pending.count
    }

    func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, dropped, lastAudio, rms)
        pending = []; dropped = 0
        return result
    }

    func discardBufferedAudio() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: false); dropped = 0; rms = 0
    }

    func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        callbacks.wait()
    }
}
