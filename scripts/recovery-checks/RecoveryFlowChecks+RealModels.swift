import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    @MainActor static func checkPhraseCleanupModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-phrase-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let probe = Probe()
        let fragments = ["I think uh", "we could get", "faster output to the live view."]
        let service = SpeechService(dependencies: .init(infer: { _, job, _ in
            guard let index = job.samples.first.map(Int.init), index > 0 else {
                return SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
            }
            let text = fragments[index - 1]
            let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                startSeconds: job.offset, endSeconds: job.offset + 3, text: text, speakerID: "speaker-1", mode: "ambient")
            return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = true
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        for index in 1...3 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            while try store.session(id: service.timeline.activeSessionID!).count < index {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let before = try store.session(id: service.timeline.activeSessionID!).map(\.text)
        precondition(before == fragments, "Recognition did not publish before phrase cleanup")
        await service.waitForRecoveryVerification()
        let after = try store.session(id: service.timeline.activeSessionID!).map(\.text).joined(separator: " ")
        precondition(after == "I think we could get faster output to the live view.", "Real model did not clean the complete phrase: \(after)")
        precondition(service.recoveryDiagnostics["cleanupRequested"] as? Int == 1, "Transport fragments became separate cleanup requests")
        service.shutdown()
        print("PASS: actual Foundation Model cleans the three published fragments as one phrase and persists their replacement.")
    }

    /// Actual on-device generation must distinguish fragments from short complete sentences.
    @MainActor static func checkDictationProse() async throws {
        let cleanup = TranscriptCleanup(purpose: .dictation)
        for (source, expected) in [("the blue one.", "the blue one"), ("tomorrow morning.", "tomorrow morning"),
                                   ("I want the blue one", "I want the blue one."), ("Go now", "Go now.")] {
            let result = await cleanup.cleanWithOutcome([source], timeout: .seconds(12))
            precondition(result.texts.first?.lowercased() == expected.lowercased(),
                         "Dictation punctuation failed for synthetic fixture \(source): \(result.texts), \(result.outcome)")
        }
        print("PASS: the real cleanup model leaves phrase fragments open and punctuates complete sentences, including short ones.")
    }

    @MainActor static func checkRealRecognition(_ file: URL) async throws {
        let source = try AudioClock.resample(file)
        let samples = source + source
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-real-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let probe = Probe()
        probe.deliveryFails = false
        let service = SpeechService(dependencies: .init(
            infer: { pipeline, job, tuning in try await pipeline.infer(job, tuning: tuning) },
            deliver: { _, text in try probe.deliver(text) },
            now: { probe.now }))
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        try await service.pipeline.prepare()
        let fullStarted = ContinuousClock.now
        let full = try await service.pipeline.testFile(file)
        print("FULL ASR: \(AudioClock.seconds(samples: source.count)) audio seconds, \(fullStarted.duration(to: .now)) elapsed.")
        print("FULL ASR TEXT: \(full.text)")
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        service.dictation.begin()
        let started = ContinuousClock.now
        for lower in stride(from: 0, to: samples.count, by: 48_000) {
            let chunk = Array(samples[lower..<min(lower + 48_000, samples.count)])
            probe.now += AudioClock.seconds(samples: chunk.count)
            service.ingestRecoveryVerification(samples: chunk, at: probe.now)
            await service.waitForRecoveryVerification()
        }
        service.dictation.end()
        await service.waitForRecoveryVerification()
        let text = probe.delivered.last ?? ""
        precondition(probe.delivered.count == 1 && !text.isEmpty, "Real recognition did not deliver the held fixture")
        // Each released hold also records one dictation timing whose audio is the whole hold. Recognition
        // chunks are recorded as ambient and carry inference time when they succeed; the timing never does.
        let jobs = service.diagnostics.report.jobs
        let isHoldTiming = { (job: PerformanceJob) in job.mode == .dictation && job.inferenceSeconds == nil }
        let durations = jobs.filter { !isHoldTiming($0) }.map(\.audioSeconds)
        precondition(!durations.isEmpty && durations.allSatisfy { $0 <= 3.001 }, "Real recognition received a long blocking chunk")
        let heldSeconds = AudioClock.seconds(samples: samples.count)
        let holds = jobs.filter(isHoldTiming)
        precondition(holds.count == 1 && abs(holds[0].audioSeconds - heldSeconds) < 0.01 && holds[0].outcome == .completed,
            "The released hold did not record one completed timing for the \(heldSeconds) s it held")
        print("REAL ASR: \(heldSeconds) audio seconds, \(durations.count) chunks, a \(holds[0].audioSeconds) s hold timing, \(started.duration(to: .now)) elapsed.")
        // The source must be a synthetic fixture; never pass private recorded audio
        // when retaining this log or posting it in a PR.
        print("REAL ASR TEXT: \(text)")
        // The hold's final job reset the recognition window, so a boundary now closes a chunk of
        // only the fixture's loudest quarter second: under the recognizer's 0.3-second minimum.
        let width = AudioClock.samples(seconds: 0.25)
        let energy = { (start: Int) in source[start..<min(start + width, source.count)].reduce(0) { $0 + $1 * $1 } }
        let loudest = stride(from: 0, through: max(0, source.count - width), by: 160).max { energy($0) < energy($1) } ?? 0
        let failuresBefore = service.transcriber.recognitionFailures
        let rowsBefore = try store.session(id: service.timeline.activeSessionID!).count
        probe.now += 0.25
        service.ingestRecoveryVerification(samples: Array(source[loudest..<min(loudest + width, source.count)]), at: probe.now)
        service.flushRecoveryVerification()
        await service.waitForRecoveryVerification()
        precondition(service.transcriber.recognitionFailures == failuresBefore, "A 0.25-second final job failed recognition: \(service.notice)")
        let shortText = try store.session(id: service.timeline.activeSessionID!).dropFirst(rowsBefore).map(\.text).joined(separator: " ")
        print("REAL SHORT FINAL: a 0.25 s final job completed; text: \(shortText.isEmpty ? "(none)" : shortText)")
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        service.shutdown()
    }
}
