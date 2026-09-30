import Foundation
import JotCore

private struct TranscriberSavedBlock: Sendable {
    let rows: [Transcript]
    let failure: String?
}

/// Chunk-to-row recognition: the queue of audio the listening timeline cuts, one recognition at a time, and saving each block's rows and word evidence before cleanup runs.
@MainActor
final class Transcriber {
    /// Cut chunks waiting for recognition, oldest first. The listening timeline hands them to `enqueue`.
    private(set) var jobs: [AudioJob] = []
    private(set) var processing: Task<Void, Never>?
    private var processingJob: AudioJob?
    /// Audio in the block being recognized, for the diagnostics' buffered figure.
    private(set) var inFlightAudioSeconds = 0.0
    private(set) var recognitionFailures = 0
    /// No screen shows these, so they are not published: they change on every recognition, and publishing them would tell the window to redraw.
    private(set) var processedAudioSeconds = 0.0
    private(set) var lastTranscriptAt: Date?
    /// The Activity screen shows these and redraws with the CPU readout once a second, so they are not published either: they change after every recognition, including the silent chunk recognized every 0.8 seconds of quiet. Queued audio counts the chunk the same tick has just cut, before the worker takes it, so publishing it told the whole window to redraw whenever the status second landed on a chunk close, about every four seconds of quiet.
    private(set) var lagSeconds = 0.0
    private(set) var lastInferenceSeconds = 0.0
    /// Whether the last block taken for recognition closed its recognition window. A block that follows a closed one and closes its own holds a whole utterance, not the first second of continuing speech.
    private var lastJobWasFinal = true
    /// Set by the service's once-a-second status work, and cleared when models unload.
    var queuedSeconds = 0.0
    private unowned let service: SpeechService
    private let library: SessionLibrary
    private let cleanup: LiveCleanup
    private let recordedRows: (AudioJob) -> Void
    private let recognitionCompleted: (AudioJob) -> Void
    private let recognitionFailed: (AudioJob) -> Void

    init(service: SpeechService, library: SessionLibrary, cleanup: LiveCleanup,
         recordedRows: @escaping (AudioJob) -> Void,
         recognitionCompleted: @escaping (AudioJob) -> Void,
         recognitionFailed: @escaping (AudioJob) -> Void) {
        self.service = service
        self.library = library
        self.cleanup = cleanup
        self.recordedRows = recordedRows
        self.recognitionCompleted = recognitionCompleted
        self.recognitionFailed = recognitionFailed
    }

    /// Nothing queued and nothing being recognized.
    var isIdle: Bool { processing == nil && jobs.isEmpty }

    /// Seconds of audio waiting in the queue, not counting the block being recognized.
    var queuedAudioSeconds: Double { jobs.reduce(0) { $0 + AudioClock.seconds(samples: $1.samples.count) } }

    /// No block of this session is queued or being recognized.
    func isDone(session id: String) -> Bool { jobs.allSatisfy { $0.sessionID != id } && processing == nil }

    func cancel() { processing?.cancel() }

    /// Queues a cut chunk. `kick` starts it when models are ready and nothing else is being recognized.
    func enqueue(_ job: AudioJob) { jobs.append(job) }

    /// Starts recognizing the oldest queued block when models are ready and nothing else is being recognized. Each block starts the next when it finishes.
    func kick() {
        guard service.lifecycle.phase == .ready, processing == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        let wholeUtterance = job.isFinal && lastJobWasFinal
        lastJobWasFinal = job.isFinal
        processingJob = job
        let generation = service.lifecycle.generation
        let began = ProcessInfo.processInfo.systemUptime
        let waitSeconds = max(0, began - job.submittedUptime)
        inFlightAudioSeconds = AudioClock.seconds(samples: job.samples.count)
        let owner = service
        processing = Task {
            defer { withExtendedLifetime(owner) {} }
            var outcome = PerformanceJob.Outcome.completed
            var inferenceSeconds: Double?
            var speechProbability: Double?
            do {
                let output = try await service.dependencies.infer(service.pipeline, job, service.tuning)
                try Task.checkCancellation()
                guard service.lifecycle.acceptsWork(generation) else { throw CancellationError() }
                inferenceSeconds = output.processingSeconds
                speechProbability = output.speechProbability.map(Double.init)
                // A lone "Mm-hmm" or "Yeah" in a quiet room is usually a throat clear or a chair; it goes no further than recognition. A leading "Okay," of continuing speech is kept.
                // A held dictation keeps its fillers only when the voice detector clearly heard them: a hold with nothing said decodes the cold microphone's first moments as "Yeah".
                let unclear = job.keepsFillers ? (output.speechProbability ?? 1) < NoiseFillers.dictatedConfidence : wholeUtterance
                let fillerOnly = unclear && service.settings.bool(JotSettings.dropFillerOnlyBlocks) && NoiseFillers.isFillerOnly(output.text)
                outcome = fillerOnly ? .fillerOnly : output.text.isEmpty ? .noSpeech : .completed
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += AudioClock.seconds(samples: job.samples.count)
                lagSeconds = max(0, service.dependencies.now().timeIntervalSince(job.startedAt) - job.offset - AudioClock.seconds(samples: job.samples.count))
                // Persist recognition before awaiting optional cleanup. Capture keeps draining while we await.
                let sources = fillerOnly ? [] : output.transcripts
                // A quiet chunk has no rows, so it skips the store; cleanup below still gets its final boundary.
                if !sources.isEmpty, !(await library.waitForDeletion(job.sessionID)) {
                    // Live must see recognition before the model's cleanup suspension. It adds each row once it is saved, without re-reading the session, so a row saved before a later one fails still shows.
                    // Recent rows, Sessions and Dictations take in every saved row when the block ends, even when a later row or the words fail.
                    // Word evidence is kept in the session's clock so a saved session can be regrouped later.
                    let words = sources.flatMap { transcript in
                        (output.wordsByTranscript[transcript.id] ?? []).enumerated().map { position, word in
                            StoredWord(transcriptID: transcript.id, position: position, word: word.text, startSeconds: job.offset + word.start, endSeconds: job.offset + word.end, probabilities: word.probabilities)
                        }
                    }
                    guard let store = library.store else { throw JotError.message("Transcript storage is unavailable.") }
                    let operation = library.storeExecutor.submit { () -> TranscriberSavedBlock in
                        var saved: [Transcript] = []
                        do {
                            for transcript in sources {
                                try store.append(transcript)
                                saved.append(transcript)
                            }
                            try store.appendWords(words)
                            return TranscriberSavedBlock(rows: saved, failure: nil)
                        } catch {
                            return TranscriberSavedBlock(rows: saved, failure: error.localizedDescription)
                        }
                    }
                    let result = try await operation.value
                    // A delete submitted after this write may still be settling. On failure
                    // the saved prefix remains valid; on success it must not return to Live.
                    if !(await library.waitForDeletion(job.sessionID)) {
                        for transcript in result.rows { library.appendLive([transcript]) }
                        library.didSave(result.rows)
                        if let failure = result.failure { throw JotError.message(failure) }
                        if !sources.isEmpty {
                            lastTranscriptAt = service.dependencies.now()
                            recordedRows(job)
                        }
                    }
                }
                if !(await library.waitForDeletion(job.sessionID)) {
                    cleanup.scheduleCleanup(sources: sources, final: job.isFinal)
                    recognitionCompleted(job)
                }
            } catch {
                outcome = error is CancellationError ? .cancelled : .failed
                recognitionFailures += 1
                recognitionFailed(job)
                if !(error is CancellationError) { service.recordEvent(.processingError, error.localizedDescription, session: job.sessionID) }
                if service.lifecycle.acceptsWork(generation) {
                    service.notice = "Ambient: \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            // recordPerformance stamps the time the block finished.
            service.recordPerformance(.init(elapsedSeconds: 0,
                mode: .ambient, outcome: outcome,
                audioSeconds: AudioClock.seconds(samples: job.samples.count), queueWaitSeconds: waitSeconds,
                inferenceSeconds: inferenceSeconds, completionSeconds: max(0, ProcessInfo.processInfo.systemUptime - job.submittedUptime),
                cleanupSeconds: nil, deliverySeconds: nil, speechProbability: speechProbability))
            inFlightAudioSeconds = 0
            processingJob = nil
            processing = nil
            // Only an idle app needs a redraw when recognition releases Install Update.
            // The recovery harness feeds ambient audio without starting a microphone, so
            // canInstallUpdate alone is true there even while listening is active.
            if !service.ambientEnabled && service.canInstallUpdate { service.objectWillChange.send() }
            service.samplePerformance()
            kick()
        }
    }

    /// Returns once every block of the session up to `offset` that was queued or being recognized when called has been recognized.
    func waitUntilProcessed(sessionID: String, through offset: Double) async {
        let barrierTickets = Set(jobs.filter { $0.sessionID == sessionID && $0.offset <= offset }.map(\.ticket)
            + (processingJob.map { $0.sessionID == sessionID ? [$0.ticket] : [] } ?? []))
        while !Task.isCancelled,
              jobs.contains(where: { barrierTickets.contains($0.ticket) }) ||
              processingJob.map({ barrierTickets.contains($0.ticket) }) == true {
            kick()
            // A sub-minimum tail has no inference job. Everything schedulable is done.
            if processing == nil && jobs.allSatisfy({ $0.sessionID != sessionID }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
