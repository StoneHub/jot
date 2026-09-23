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
    private var probabilities: [Int: [Float]] = [:]
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
        asr = nil; vad = nil; diarizer = nil; lastSpeaker = nil
        probabilities.removeAll(keepingCapacity: false)
        recognitionWindow.reset()
        sessionID = ""; expectedOffset = 0; baseOffset = 0
    }

    func testFile(_ url: URL, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw JotError.message("Diagnostic files must be at most 60 seconds.") }
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await infer(AudioJob(sessionID: UUID().uuidString, startedAt: Date(), offset: 0,
            samples: samples, mode: .ambient, ticket: UUID(), isFinal: true), tuning: tuning)
    }

    func infer(_ job: AudioJob, tuning: TranscriptionTuning = .init()) async throws -> SpeechOutput {
        guard let asr, let vad, let diarizer else { throw JotError.message("Prepare models before listening.") }
        try Task.checkCancellation()
        let begin = Date()
        var recognitionPlan: RecognitionCommitWindow.Plan?
        var recognitionPlanResolved = job.mode != .ambient
        if job.mode == .ambient {
            if sessionID != job.sessionID || abs(job.offset - expectedOffset) > 0.02 {
                diarizer.reset(); probabilities.removeAll(); recognitionWindow.reset()
                sessionID = job.sessionID; baseOffset = job.offset; lastSpeaker = nil
            }
            expectedOffset = job.offset + Double(job.samples.count) / 16000
            recognitionPlan = recognitionWindow.plan(sessionID: job.sessionID, offset: job.offset,
                newSamples: job.samples, isFinal: job.isFinal)
            if !job.samples.isEmpty {
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
            }
            let keepFrom = Int((job.offset - baseOffset - 2) / 0.08)
            probabilities = probabilities.filter { $0.key >= keepFrom }
        }
        let recognitionSamples = recognitionPlan?.samples ?? job.samples
        defer {
            // A final barrier or failed inference closes this recognition
            // segment. SpeechService records a gap after errors, while the
            // pipeline must not grow or replay unbounded failed audio.
            if job.mode == .ambient && (job.isFinal || !recognitionPlanResolved) {
                recognitionWindow.reset()
            }
        }
        guard !recognitionSamples.isEmpty else {
            if let recognitionPlan { recognitionWindow.commit(recognitionPlan) }
            recognitionPlanResolved = true
            return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin))
        }
        // Conservative neural speech gate; uncertain speaker attribution does not suppress ASR.
        let activity = try await vad.process(recognitionSamples)
        guard activity.contains(where: { $0.probability >= 0.20 }) else {
            if let recognitionPlan { recognitionWindow.commit(recognitionPlan) }
            recognitionPlanResolved = true
            return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin))
        }
        try Task.checkCancellation()
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(recognitionSamples, decoderState: &state)
        try Task.checkCancellation()
        let allWords = result.tokenTimings.map { buildWordTimings(from: $0) } ?? []
        let words: [WordTiming]
        if let recognitionPlan {
            guard result.tokenTimings != nil else {
                throw JotError.message("Streaming recognition did not return word timing data.")
            }
            words = recognitionWindow.newWords(from: allWords, for: recognitionPlan)
        } else {
            words = allWords
        }
        let rawText = result.tokenTimings == nil ? result.text : words.map(\.word).joined(separator: " ")
        let text = SpokenSymbols.applying(to: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let recognitionPlan { recognitionWindow.commit(recognitionPlan, words: words) }
        recognitionPlanResolved = true
        guard !text.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: Date().timeIntervalSince(begin)) }
        var segments: [Transcript] = []
        var wordsByTranscript: [String: [AttributedWord]] = [:]
        if job.mode == .ambient, let recognitionPlan, !words.isEmpty {
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
                    text: SpokenSymbols.applying(to: turn.text), speakerID: turn.speaker, mode: job.mode.rawValue)
            }
            wordsByTranscript = Dictionary(uniqueKeysWithValues: zip(segments, turns).map { ($0.id, Array(attributed[$1.wordRange])) })
        }
        if segments.isEmpty {
            segments = [Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                endSeconds: job.offset + Double(job.samples.count) / 16000, text: text, speakerID: nil, mode: job.mode.rawValue)]
        }
        return SpeechOutput(transcripts: segments, text: text, processingSeconds: Date().timeIntervalSince(begin), wordsByTranscript: wordsByTranscript)
    }
}
