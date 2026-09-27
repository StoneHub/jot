import Foundation
import JotCore

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
    /// Set by the service's once-a-second status work, and cleared when models unload.
    var queuedSeconds = 0.0
    private unowned let service: SpeechService

    init(service: SpeechService) { self.service = service }

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
        processingJob = job
        let generation = service.lifecycle.generation
        let began = ProcessInfo.processInfo.systemUptime
        let waitSeconds = max(0, began - job.submittedUptime)
        inFlightAudioSeconds = AudioClock.seconds(samples: job.samples.count)
        processing = Task {
            var outcome = PerformanceJob.Outcome.completed
            var inferenceSeconds: Double?
            do {
                let output = try await service.dependencies.infer(service.pipeline, job, service.tuning)
                try Task.checkCancellation()
                guard service.lifecycle.acceptsWork(generation) else { throw CancellationError() }
                inferenceSeconds = output.processingSeconds
                outcome = output.text.isEmpty ? .noSpeech : .completed
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += AudioClock.seconds(samples: job.samples.count)
                lagSeconds = max(0, service.dependencies.now().timeIntervalSince(job.startedAt) - job.offset - AudioClock.seconds(samples: job.samples.count))
                // Persist recognition before awaiting optional cleanup. Capture keeps draining while we await.
                let sources = output.transcripts
                let library = service.library
                if !library.sessionIsDeleted(job.sessionID) {
                    // Live must see recognition before the model's cleanup suspension. It adds each row once it is saved, without re-reading the session, so a row saved before a later one fails still shows.
                    // Recent rows, Sessions and Dictations take in every saved row when the block ends, even when a later row or the words fail.
                    var saved: [Transcript] = []
                    defer { library.didSave(saved) }
                    for transcript in sources {
                        try library.store?.append(transcript)
                        saved.append(transcript)
                        library.appendLive([transcript])
                    }
                    // Word evidence is kept in the session's clock so a saved session can be regrouped later.
                    let words = sources.flatMap { transcript in
                        (output.wordsByTranscript[transcript.id] ?? []).enumerated().map { position, word in
                            StoredWord(transcriptID: transcript.id, position: position, word: word.text, startSeconds: job.offset + word.start, endSeconds: job.offset + word.end, probabilities: word.probabilities)
                        }
                    }
                    try library.store?.appendWords(words)
                    if !sources.isEmpty {
                        lastTranscriptAt = service.dependencies.now()
                        if job.sessionID == service.timeline.sessionID { service.timeline.lastAmbientRowAt = service.dependencies.now() }
                    }
                }
                service.cleanup.scheduleCleanup(sources: sources, final: job.isFinal)
                service.dictation.updateAttemptText(for: job)
            } catch {
                outcome = error is CancellationError ? .cancelled : .failed
                recognitionFailures += 1
                service.dictation.noteRecognitionFailure(for: job)
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
                cleanupSeconds: nil, deliverySeconds: nil))
            inFlightAudioSeconds = 0
            processingJob = nil
            processing = nil
            // Install Update waits for this job, and nothing else publishes when it ends. Only an ending that allows the update redraws, so listening never does.
            if service.canInstallUpdate { service.objectWillChange.send() }
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
