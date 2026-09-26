import Foundation
import AVFoundation
import CoreML
import FluidAudio
import JotCore

/// One inference worker. The controller never submits overlapping jobs.
actor SpeechPipeline {
    private var asr: AsrManager?
    private var vad: VadManager?
    private var diarizer: SortformerDiarizer?
    private var sessionID = ""
    private var expectedOffset: Double = 0
    private var baseOffset: Double = 0
    /// Speaker probabilities by 0.08-second frame of the session clock, counted from `baseOffset`.
    private var probabilities: [Int: [Float]] = [:]
    /// Holds quiet audio back from the speaker model and maps its frames onto the session clock.
    private var speakerFeed = SpeakerModelFeed()
    private var recognitionWindow = RecognitionCommitWindow()
    /// Last confirmed speaker of the previous ambient block, carried forward while audio stays continuous.
    private var lastSpeaker: String?
    /// Prepared and released with the live models, but run on its own actor so a long pass never blocks live inference.
    nonisolated let speakerPass = SpeakerPass()

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
        try Task.checkCancellation()
        try await speakerPass.prepare()
    }

    func unload() async {
        await speakerPass.unload()
        asr = nil; vad = nil; diarizer = nil; lastSpeaker = nil; speakerFeed.reset()
        probabilities.removeAll(keepingCapacity: false)
        recognitionWindow.reset()
        sessionID = ""; expectedOffset = 0; baseOffset = 0
    }

    func testFile(_ url: URL, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw JotError.message("Diagnostic files must be at most 60 seconds.") }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await infer(AudioJob(sessionID: UUID().uuidString, startedAt: Date(), offset: 0,
            samples: samples, ticket: UUID(), isFinal: true), tuning: tuning)
    }

    func infer(_ job: AudioJob, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        guard let asr, let vad, let diarizer else { throw JotError.message("Prepare models before listening.") }
        try Task.checkCancellation()
        let begin = Date()
        var recognitionPlanResolved = false
        if sessionID != job.sessionID || abs(job.offset - expectedOffset) > 0.02 {
            diarizer.reset(); speakerFeed.reset(); probabilities.removeAll(); recognitionWindow.reset()
            sessionID = job.sessionID; baseOffset = job.offset; lastSpeaker = nil
        }
        expectedOffset = job.offset + Double(job.samples.count) / 16000
        let recognitionPlan = recognitionWindow.plan(sessionID: job.sessionID, offset: job.offset,
            newSamples: job.samples, isFinal: job.isFinal)
        let recognitionSamples = recognitionPlan.samples
        defer {
            // A final barrier or failed inference closes this recognition
            // segment. SpeechService records a gap after errors, while the
            // pipeline must not grow or replay unbounded failed audio.
            if job.isFinal || !recognitionPlanResolved {
                recognitionWindow.reset()
            }
        }
        // Conservative neural speech gate; uncertain speaker attribution does not suppress ASR.
        // It runs before the speaker model so quiet audio is held back from it rather than fed.
        var heardSpeech = false
        if !recognitionSamples.isEmpty {
            do {
                heardSpeech = try await vad.process(recognitionSamples).contains(where: { $0.probability >= 0.20 })
            } catch {
                // Held, not lost: the model's frames stay on the session clock after a failed job.
                speakerFeed.holdQuiet(job.samples)
                throw error
            }
        }
        if heardSpeech {
            let audio = speakerFeed.releaseForSpeech(job.samples)
            if !audio.isEmpty {
                diarizer.addAudio(audio)
                while let update = try diarizer.process() {
                    try Task.checkCancellation()
                    let chunk = update.chunkResult
                    for frame in 0..<chunk.finalizedFrameCount {
                        probabilities[speakerFeed.sessionFrame(forModelFrame: chunk.startFrame + frame)] = (0..<4).map { chunk.probability(speaker: $0, frame: frame, numSpeakers: 4) }
                    }
                    for frame in 0..<chunk.tentativeFrameCount {
                        probabilities[speakerFeed.sessionFrame(forModelFrame: chunk.tentativeStartFrame + frame)] = (0..<4).map { chunk.tentativeProbability(speaker: $0, frame: frame, numSpeakers: 4) }
                    }
                }
            }
        } else {
            speakerFeed.holdQuiet(job.samples)
        }
        let keepFrom = Int((job.offset - baseOffset - 2) / 0.08)
        probabilities = probabilities.filter { $0.key >= keepFrom }
        guard heardSpeech else {
            recognitionWindow.commit(recognitionPlan)
            recognitionPlanResolved = true
            return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin))
        }
        try Task.checkCancellation()
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(recognitionSamples, decoderState: &state)
        try Task.checkCancellation()
        guard let tokenTimings = result.tokenTimings else {
            throw JotError.message("Streaming recognition did not return word timing data.")
        }
        let words = recognitionWindow.newWords(from: buildWordTimings(from: tokenTimings), for: recognitionPlan)
        let text = words.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionWindow.commit(recognitionPlan, words: words)
        recognitionPlanResolved = true
        guard !text.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin)) }
        var segments: [Transcript] = []
        var wordsByTranscript: [String: [AttributedWord]] = [:]
        if !words.isEmpty {
            let attributed = words.map { word -> AttributedWord in
                let start = recognitionPlan.bufferOffset + word.startTime - job.offset
                let end = recognitionPlan.bufferOffset + word.endTime - job.offset
                let frame = Int((job.offset - baseOffset + (start + end) / 2) / 0.08)
                return AttributedWord(text: word.word, start: start, end: end, probabilities: probabilities[frame] ?? [])
            }
            let turns = TranscriptGrouping.turns(attributed, tuning: tuning, continuing: lastSpeaker)
            if let final = turns.last?.speaker, final != "overlap" { lastSpeaker = final }
            segments = turns.map { turn in
                Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + turn.start, endSeconds: job.offset + turn.end,
                    text: turn.text, speakerID: turn.speaker, mode: "ambient")
            }
            wordsByTranscript = Dictionary(uniqueKeysWithValues: zip(segments, turns).map { ($0.id, Array(attributed[$1.wordRange])) })
        }
        if segments.isEmpty {
            segments = [Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                endSeconds: job.offset + Double(job.samples.count) / 16000, text: text, speakerID: nil, mode: "ambient")]
        }
        return SpeechOutput(transcripts: segments, text: text, processingSeconds: Date().timeIntervalSince(begin), wordsByTranscript: wordsByTranscript)
    }
}
