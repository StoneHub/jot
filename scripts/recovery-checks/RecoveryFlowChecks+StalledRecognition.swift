import Foundation
import JotCore
import JotEngine

/// Holds every recognition until the check lets go, like a recognizer that never answers.
@MainActor private final class StallGate { var held = true }

extension RecoveryFlowChecks {
    /// A recognizer that never answers (#357). Listening keeps the blocks it has queued, final ones included, but takes no
    /// more audio past the budget and accounts for the rest as one gap; a released dictation and Pause stop waiting on it
    /// and say so; and once the models are loaded again the queue moves on, starting with the block it was stuck on.
    @MainActor static func checkStalledRecognition(directory: URL) async throws {
        let gate = StallGate()
        let probe = Probe()
        probe.deliveryFails = false
        let store = try TranscriptStore(directory: directory.appendingPathComponent("stalled"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                while gate.held { try await Task.sleep(for: .milliseconds(5)) }
                return probe.infer(job)
            }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        // Ten seconds of queued audio instead of ten minutes, and a stall after a fifth of a second instead of thirty.
        let budget = 10.0
        service.timeline.backlog = RecognitionBacklog(budgetSeconds: budget, headroomSeconds: 3)
        service.transcriber.stallSeconds = 0.2
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let first = service.timeline.sessionID
        let chunkSeconds = 2.8
        // Two seconds of sound and 0.8 s of quiet: the quiet closes the chunk, so it is a final block like a sentence's.
        func speak(_ index: Int) {
            probe.now += chunkSeconds
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 32_000), at: probe.now)
            service.ingestRecoveryVerification(samples: Array(repeating: 0, count: 12_800), rms: 0, at: probe.now)
        }
        func gapEvents() async throws -> [CaptureEvent] {
            await service.storeExecutor.flush()
            return try store.events(sessionID: first).filter { $0.kind == "audio_gap" }
        }

        speak(1); speak(2); speak(3)
        // Three seconds of sound with no quiet closes at the chunk limit, so this block is not final.
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: 4, count: 48_000), at: probe.now)
        precondition(service.transcriber.processing != nil && service.transcriber.jobs.count == 3, "The first block did not stall in recognition with three queued")
        precondition(service.transcriber.jobs.last?.isFinal == false, "The chunk limit closed a final block")
        precondition(!service.timeline.backlog.isFull && service.droppedSeconds == 0, "Audio under the budget was withheld")
        speak(5); speak(6)
        let queued = service.transcriber.queuedAudioSeconds
        precondition(service.transcriber.jobs.count == 3 && queued <= budget, "The queue grew past its budget: \(queued) s")
        precondition(service.transcriber.jobs.last?.isFinal == true, "The queued tail was not closed when the audio after it was withheld")
        precondition(service.timeline.backlog.isFull && abs(service.droppedSeconds - 2 * chunkSeconds) < 0.001, "Withheld audio was not accounted for: \(service.droppedSeconds) s")
        precondition(service.notice.hasPrefix("Recognition has fallen behind"), "The full queue was not announced: \(service.notice)")
        var events = try await gapEvents()
        precondition(events.count == 1 && events[0].durationSeconds == nil, "The gap did not record one open event: \(events)")
        print("PASS: a stalled recognizer keeps its queued blocks, final ones included, and withholds audio past the budget as one open gap.")

        // A hold released into the stall is saved for review with its gap, without waiting for the recognizer.
        service.dictation.begin()
        probe.now += 2
        service.ingestRecoveryVerification(samples: Array(repeating: 7, count: 32_000), at: probe.now)
        service.dictation.end()
        await service.dictation.waitForRecovery()
        // The whole hold was withheld, so the saved attempt carries its gap and no words. With nothing to insert or retry it
        // is not offered for review (the recoverable query wants text); the notices say what happened instead.
        let attempt = service.dictation.currentAttempt
        precondition(attempt?.state == .deliveryFailed && attempt?.hasGap == true && attempt?.text == "" && probe.delivered.isEmpty,
                     "A dictation released into the stall was not saved with its gap: \(String(describing: attempt))")
        let offered = try store.latestRecoverableDictationAttempt()
        precondition(offered == nil, "An empty stalled hold was offered for review: \(String(describing: offered))")
        precondition(service.recoveryNotice.hasPrefix("Recognition stalled"), "The stalled dictation was not announced: \(service.recoveryNotice)")
        print("PASS: a dictation released into the stall is saved with its gap once the wait gives up.")

        // Pause finishes without the recognizer, keeps the queued blocks for a restart, and closes the session's gap with its length.
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!service.ambientEnabled && service.notice.hasPrefix("Paused, but recognition stalled"), "Pause did not report the stall: \(service.notice)")
        precondition(service.transcriber.jobs.count == 3 && service.transcriber.processing != nil, "Pause dropped the queued blocks")
        events = try await gapEvents()
        let closed = events.compactMap(\.durationSeconds)
        precondition(events.count == 2 && closed.count == 1, "The session's end did not close the gap: \(events)")
        precondition(abs(closed[0] - service.droppedSeconds) < 0.001, "The closed gap's length is not the withheld audio: \(closed[0]) s of \(service.droppedSeconds) s")
        print("PASS: Pause does not wait for a stalled recognizer, and the session end records the gap's length.")

        // Unload and reload the models while the first block still hangs: the queue moves on, starting with that block.
        let token = service.lifecycle.beginPause()!
        service.lifecycle.finishPause(token)
        gate.held = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        service.transcriber.kick()
        await service.waitForRecoveryVerification()
        let rows = try store.session(id: first).filter { $0.mode == "ambient" }
        precondition(rows.map(\.text) == ["segment1", "segment2", "segment3", "segment4"], "The reloaded recognizer did not take the queued blocks in order: \(rows.map(\.text))")
        let starts = rows.map(\.startSeconds)
        precondition(zip(starts, [0, chunkSeconds, 2 * chunkSeconds, 3 * chunkSeconds]).allSatisfy { abs($0 - $1) < 0.001 }, "Recognized rows lost their place on the session clock: \(starts)")
        speak(8)
        await service.waitForRecoveryVerification()
        let resumed = try store.session(id: service.timeline.sessionID)
        precondition(resumed.map(\.text) == ["segment8"] && !service.timeline.backlog.isFull, "Audio was not queued again after the restart")
        print("PASS: reloading the models releases the stalled block back to the queue, and listening takes audio again.")
    }
}
