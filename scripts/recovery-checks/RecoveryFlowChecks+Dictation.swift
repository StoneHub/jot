import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// A one-word hold bypasses prose generation even when cleanup is enabled. Recognition stays saved as heard.
    @MainActor static func checkSingleWordDictation(directory: URL) async throws {
        let store = try TranscriptStore(directory: directory.appendingPathComponent("single-word"))
        let probe = Probe()
        probe.deliveryFails = false
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset, endSeconds: job.offset + AudioClock.seconds(samples: job.samples.count),
                    text: "purple.", mode: "ambient")
                return SpeechOutput(transcripts: [row], text: row.text, processingSeconds: 0)
            }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now },
            cleanup: { _, _, _ in preconditionFailure("A single word reached the prose model") },
            intelligenceAvailability: { .available }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false
        service.cleanUpDictation = true
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        service.dictation.begin()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(5), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        service.dictation.end()
        await service.waitForRecoveryVerification()
        precondition(probe.delivered == ["purple"], "A single word acquired sentence punctuation")
        let rows = try store.session(id: service.timeline.activeSessionID!)
        precondition(rows.contains { $0.mode == "ambient" && $0.text == "purple." }, "Recognition source was changed")
        precondition(rows.contains { $0.mode == "dictation" && $0.text == "purple" }, "Saved dictation differs from insertion")
        service.shutdown()
        print("PASS: a single word bypasses prose cleanup, inserts without a period, and preserves its recognized source.")
    }

    /// A silence-bounded block recognized as only "Mm-hmm." while listening is not saved and is recorded as filler only. The same words are kept as the first chunk of continuing speech and when held as a dictation, and a block with any other word is kept. The setting turns the filter off.
    @MainActor static func checkFillerOnlyBlocksAreNotSaved(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let store = try TranscriptStore(directory: directory.appendingPathComponent("filler-only"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                // 7 is a chair scrape, 8 a clearly spoken "Mm-hmm", 9 a cold microphone's first moments heard as "Yeah".
                guard let first = job.samples.first, [7, 8, 9].contains(first) else { return probe.infer(job) }
                let duration = AudioClock.seconds(samples: job.samples.count)
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                    endSeconds: job.offset + duration, text: first == 9 ? "Yeah." : "Mm-hmm.", mode: "ambient")
                let peak: Float = first == 8 ? 0.95 : first == 9 ? 0.45 : 0.25
                return SpeechOutput(transcripts: [row], text: row.text, processingSeconds: 0.001, speechProbability: peak)
            },
            deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false; service.cleanUpDictation = false
        // Reset first too: a failed precondition traps before the defer, which would leave the filter off for the next run.
        try? service.settings.reset(JotSettings.dropFillerOnlyBlocks)
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown(); try? service.settings.reset(JotSettings.dropFillerOnlyBlocks) }
        func speak(_ value: Float) async {
            probe.now += 1
            service.ingestRecoveryVerification(samples: Array(repeating: value, count: 16_000), at: probe.now)
            service.flushRecoveryVerification()
            await service.waitForRecoveryVerification()
        }

        await speak(7)
        let heard = try store.recent(limit: 20)
        precondition(heard.isEmpty, "A filler-only block heard while listening was saved")
        // The same report `jot diagnostics` returns, read back from its JSON.
        let dropped = try JSONDecoder().decode(PerformanceReport.self, from: service.diagnostics.export()).jobs.last
        precondition(dropped?.outcome == .fillerOnly, "A dropped filler-only block was not recorded as filler only")
        precondition(dropped?.speechProbability == 0.25, "The voice detector's peak was not recorded for the job")
        await speak(3)
        let kept = try store.recent(limit: 20).map(\.text)
        precondition(kept == ["segment3"], "A block with real words was not saved")
        // A full three-second chunk is cut while the sound goes on; its words open an utterance and are kept.
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: 7, count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        service.flushRecoveryVerification()
        await service.waitForRecoveryVerification()
        let opening = try store.recent(limit: 20).filter { $0.text == "Mm-hmm." }
        precondition(opening.count == 1, "The first chunk of continuing speech was dropped as filler only")

        func dictate(_ value: Float) async {
            service.dictation.begin()
            probe.now += 1
            service.ingestRecoveryVerification(samples: Array(repeating: value, count: 16_000), at: probe.now)
            await service.waitForRecoveryVerification()
            service.dictation.end()
            await service.waitForRecoveryVerification()
        }
        await dictate(8)
        precondition(probe.delivered == ["Mm-hmm"], "A dictated filler was not inserted: \(probe.delivered)")
        await dictate(9)
        precondition(probe.delivered == ["Mm-hmm"], "A hold with no clear speech inserted \(probe.delivered)")
        let afterEmptyHold = try store.recent(limit: 20)
        precondition(afterEmptyHold.allSatisfy { !$0.text.hasPrefix("Yeah") }, "A hold with no clear speech saved a filler")
        await speak(7)
        let afterDictation = try store.recent(limit: 20).filter { $0.text == "Mm-hmm." }
        precondition(afterDictation.count == 2, "A filler-only block after a dictation was saved")

        service.settings.set(JotSettings.dropFillerOnlyBlocks, false)
        await speak(7)
        let fillers = try store.recent(limit: 20).filter { $0.text == "Mm-hmm." }
        precondition(fillers.count == 3, "Turning the filter off did not save a filler-only block")
        print("PASS: a silence-bounded filler-only block is not saved while listening, is kept when it opens continuing speech or is clearly dictated, is dropped from a hold the voice detector barely heard, and is saved with the filter off; diagnostics record its outcome and voice detector peak.")
    }

    /// Ten held dictations, five with cleanup and five without, each record release-to-insert, cleanup, and insertion time with the cleanup outcome, and the diagnostics report splits the latency by whether cleanup ran. Cleanup and insertion take known minimum times, so each cleaned dictation must be slower by at least the cleanup time.
    @MainActor static func checkDictationTimings(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let cleanupDelay = 0.3, deliveryDelay = 0.05
        let store = try TranscriptStore(directory: directory.appendingPathComponent("dictation-timings"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) },
            deliver: { _, text in
                try await Task.sleep(for: .seconds(deliveryDelay))
                return try probe.deliver(text)
            },
            now: { probe.now }, cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: {
                    try await Task.sleep(for: .seconds(cleanupDelay))
                    return $0.map { $0.capitalized }
                })
            }, intelligenceAvailability: { .available }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        for index in 1...10 {
            service.cleanUpDictation = index.isMultiple(of: 2)
            service.dictation.begin()
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(100 + index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
            service.dictation.end()
            await service.waitForRecoveryVerification()
        }
        // A hold with no speech records a timing but no release-to-insert latency.
        service.cleanUpDictation = true
        service.dictation.begin(); service.dictation.end()
        await service.waitForRecoveryVerification()
        precondition(probe.delivered.count == 10 && probe.delivered[1] == "Segment102" && probe.delivered[0] == "segment101",
            "Dictations were not inserted with and without cleanup as set")

        // The same report `jot diagnostics` returns, read back from its JSON.
        let report = try JSONDecoder().decode(PerformanceReport.self, from: service.diagnostics.export())
        let dictations = report.jobs.filter { $0.mode == .dictation }
        precondition(dictations.count == 11, "Each held dictation did not record exactly one timing")
        precondition(dictations.last?.outcome == .noSpeech && dictations.last?.deliverySeconds == nil && dictations.last?.cleanupOutcome == nil,
            "A hold with no speech was not recorded as no speech")
        let inserted = Array(dictations.prefix(10))
        for (offset, job) in inserted.enumerated() {
            let cleaned = (offset + 1).isMultiple(of: 2)
            precondition(job.outcome == .completed, "An inserted dictation was not recorded as completed")
            precondition(abs(job.audioSeconds - 3) < 0.01, "The hold length was not recorded")
            precondition((job.deliverySeconds ?? 0) >= deliveryDelay, "Insertion time was not recorded")
            if cleaned {
                precondition(job.cleanupOutcome == "changed" && (job.cleanupSeconds ?? 0) >= cleanupDelay,
                    "A cleaned dictation did not record its cleanup time and outcome")
            } else {
                precondition(job.cleanupOutcome == nil && job.cleanupSeconds == nil, "A dictation without cleanup recorded cleanup")
            }
            precondition(job.completionSeconds + 0.001 >= job.queueWaitSeconds + (job.cleanupSeconds ?? 0) + (job.deliverySeconds ?? 0),
                "Release-to-insert latency is shorter than its recognition, cleanup, and insertion time")
        }
        let with = report.dictationLatencyWithCleanup, without = report.dictationLatencyWithoutCleanup
        precondition(report.dictationLatency.count == 10 && with.count == 5 && without.count == 5,
            "The report did not split ten inserted dictations by whether cleanup ran")
        guard let withMedian = with.medianSeconds, let withP95 = with.p95Seconds,
              let withoutMedian = without.medianSeconds, let withoutP95 = without.p95Seconds else {
            preconditionFailure("The report is missing median or p95 latency")
        }
        precondition(withMedian >= cleanupDelay + deliveryDelay && withP95 >= withMedian, "Cleaned latency does not include cleanup")
        precondition(withoutMedian >= deliveryDelay && withoutP95 >= withoutMedian && withoutMedian < withMedian,
            "Latency without cleanup is not separated from latency with cleanup")
        precondition(report.dictationCleanupLatency.count == 5 && (report.dictationCleanupLatency.medianSeconds ?? 0) >= cleanupDelay,
            "The report does not state what dictation cleanup costs")
        print(String(format: "PASS: ten dictations report release-to-insert median %.2f s / p95 %.2f s with cleanup, %.2f s / %.2f s without; cleanup median %.2f s.",
            withMedian, withP95, withoutMedian, withoutP95, report.dictationCleanupLatency.medianSeconds ?? 0))
    }

    /// Quitting mid-hold leaves the attempt with the words as recognized. The next launch converts them once, so recovery inserts dictation text; a finished hold whose delivery failed already holds dictation text and is inserted as saved.
    @MainActor static func checkInterruptedHold(directory: URL) async throws {
        let probe = Probe()
        let spoken = ["email dott", "open parenthesis dott close parenthesis"]
        let dependencies = SpeechServiceDependencies(infer: { _, job, _ in
            guard let index = job.samples.first.map(Int.init), index > 0 else {
                return SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
            }
            let text = spoken[index - 1]
            let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                startSeconds: job.offset, endSeconds: job.offset + 3, text: text, mode: "ambient")
            return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now })
        let storeDirectory = directory.appendingPathComponent("interrupted")
        let store = try TranscriptStore(directory: storeDirectory)
        let first = SpeechService(dependencies: dependencies)
        first.highlightTargetField = false
        first.muteSpeakersDuringDictation = false
        first.keepAudioForSpeakerPass = false
        first.cleanUpTranscriptions = false
        first.cleanUpDictation = false
        // A name that is also a spoken symbol: converting "email Dot" again would insert "email.".
        try first.saveVocabularyEntry(VocabularyEntry(preferred: "Dot", heard: "dott"))
        first.beginRecoveryVerification(store: store, startedAt: probe.now)

        first.dictation.begin()
        probe.now += 3
        first.ingestRecoveryVerification(samples: Array(repeating: 1, count: 48_000), at: probe.now)
        await first.waitForRecoveryVerification()
        first.dictation.end()
        await first.waitForRecoveryVerification()
        let finished = try store.latestRecoverableDictationAttempt()
        precondition(finished?.text == "email Dot", "The finished hold did not save dictation text")

        first.dictation.begin()
        probe.now += 3
        first.ingestRecoveryVerification(samples: Array(repeating: 2, count: 48_000), at: probe.now)
        await first.waitForRecoveryVerification()
        let saved = try store.latestRecoverableDictationAttempt()
        precondition(saved?.text == "open parenthesis dott close parenthesis", "A recognized block converted the held text before the hold ended")
        first.shutdown()

        let reopened = try TranscriptStore(directory: storeDirectory)
        let second = SpeechService(dependencies: dependencies)
        second.highlightTargetField = false
        second.muteSpeakersDuringDictation = false
        second.keepAudioForSpeakerPass = false
        second.cleanUpTranscriptions = false
        // In the order launch runs them: load the vocabulary, open the store, finalize interrupted holds.
        try second.saveVocabularyEntry(VocabularyEntry(preferred: "Dot", heard: "dott"))
        second.beginRecoveryVerification(store: reopened, startedAt: probe.now)
        try await second.dictation.finalizeInterruptedAttempts()
        probe.deliveryFails = false
        let interruptedReview = try await second.dictation.savedDictationForReview()
        precondition(interruptedReview?.text == "(Dot)", "Interrupted hold was not converted for review")
        let repeatedReview = try await second.dictation.savedDictationForReview()
        precondition(repeatedReview == interruptedReview && probe.delivered.isEmpty, "Review inserted or consumed saved text")
        try reopened.deleteDictationAttempt(id: interruptedReview!.id)
        let finishedReview = try await second.dictation.savedDictationForReview()
        precondition(finishedReview?.text == "email Dot", "Review converted finished dictation text again")
        second.shutdown()
        print("PASS: a hold interrupted by quit is converted once at the next launch and reviewed as dictation text; a finished hold's saved text is reviewed unchanged.")
    }
}
