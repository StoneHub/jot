import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    @MainActor static func checkFailureAndCleanup(directory: URL) async throws {
        enum SyntheticFailure: Error { case recognition }
        let probe = Probe()
        probe.deliveryFails = false
        let store = try TranscriptStore(directory: directory.appendingPathComponent("failure"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                if job.isFinal && probe.failFinal { throw SyntheticFailure.recognition }
                if job.samples.first == 2 { throw SyntheticFailure.recognition }
                return probe.infer(job)
            }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        service.dictation.begin()
        for index in 1...3 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        service.dictation.end()
        await service.waitForRecoveryVerification()
        let partial = try store.latestRecoverableDictationAttempt()
        precondition(probe.delivered.isEmpty && partial?.hasGap == true && partial?.text == "segment1 segment3",
            "Recognition failure inserted a partial dictation as complete")
        service.disableDictation()
        let afterDisable = try store.latestRecoverableDictationAttempt()
        precondition(afterDisable == partial, "Disabling shortcut deleted retained speech")

        service.dictation.begin()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(4), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        probe.failFinal = true
        service.dictation.end()
        await service.waitForRecoveryVerification()
        let finalFailure = try store.latestRecoverableDictationAttempt()
        precondition(probe.delivered.isEmpty && finalFailure?.hasGap == true && finalFailure?.text == "segment4",
            "An empty final barrier failed without retaining a partial attempt")
        try store.deleteDictationAttempt(id: partial!.id)
        try store.deleteDictationAttempt(id: finalFailure!.id)
        let emptyReview = try await service.dictation.savedDictationForReview()
        precondition(emptyReview == nil && probe.delivered.isEmpty,
            "Review substituted ambient speech after saved attempts were removed")
        service.shutdown()
        print("PASS: failed recognition and empty final barriers retain partial text without automatic insertion; disabling dictation keeps it.")

        let cleanedStore = try TranscriptStore(directory: directory.appendingPathComponent("cleanup"))
        let cleaned = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) }, deliver: { _, text in try probe.deliver(text) },
            now: { probe.now }, cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: {
                    try await Task.sleep(for: .milliseconds(400))
                    return $0.map { $0.capitalized }
                })
            }, intelligenceAvailability: { .available }))
        cleaned.highlightTargetField = false; cleaned.muteSpeakersDuringDictation = false
        cleaned.keepAudioForSpeakerPass = false; cleaned.cleanUpTranscriptions = true
        cleaned.beginRecoveryVerification(store: cleanedStore, startedAt: probe.now)
        cleaned.library.showLive(cleaned.timeline.activeSessionID)
        for index in 1...2 {
            probe.now += 3
            cleaned.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            // Each explicit quiet boundary completes a phrase. The next phrase
            // must be queued while cleanup is busy, not discarded as raw forever.
            cleaned.flushRecoveryVerification()
            while try cleanedStore.session(id: cleaned.timeline.activeSessionID!).count < index {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let raw = try cleanedStore.session(id: cleaned.timeline.activeSessionID!)
        precondition(raw.map(\.text) == ["segment1", "segment2"], "Raw text did not publish before delayed cleanup")
        precondition(cleaned.library.live.paragraphs.map(\.text) == ["segment1 segment2"] && cleaned.library.live.cleanupRevision == 0,
            "Live did not show raw rows as they were saved")
        await cleaned.waitForRecoveryVerification()
        let readable = try cleanedStore.session(id: cleaned.timeline.activeSessionID!)
        precondition(readable.map(\.text) == ["Segment1", "Segment2"], "Phrase cleanup dropped work while the model was busy")
        precondition(cleaned.recoveryDiagnostics["cleanupApplied"] as? Int == 2, "Cleanup outcome was not reported")
        precondition(cleaned.library.live.paragraphs.map(\.text) == ["Segment1 Segment2"] && cleaned.library.live.cleanupRevision == 2,
            "Live did not put cleaned text in place of the raw text")
        try await libraryMatchesStore(cleaned, cleanedStore, "phrase cleanup")
        cleaned.shutdown()
        print("PASS: raw text publishes before delayed cleanup; the next recognition completes while cleanup runs, then the first row is replaced.")
        print("PASS: Live shows raw rows as they are saved and puts each cleaned phrase in place, without re-reading the session.")

        let slowStore = try TranscriptStore(directory: directory.appendingPathComponent("dictation-cleanup"))
        let slow = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) }, deliver: { _, text in try probe.deliver(text) },
            now: { probe.now }, cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: {
                    try await Task.sleep(for: .seconds(3))
                    return $0.map { $0.capitalized }
                })
            }, intelligenceAvailability: { .available }))
        slow.highlightTargetField = false; slow.muteSpeakersDuringDictation = false
        slow.keepAudioForSpeakerPass = false; slow.cleanUpTranscriptions = false
        slow.cleanUpDictation = true
        slow.beginRecoveryVerification(store: slowStore, startedAt: probe.now)
        slow.dictation.begin()
        probe.now += 3
        slow.ingestRecoveryVerification(samples: Array(repeating: Float(5), count: 48_000), at: probe.now)
        await slow.waitForRecoveryVerification()
        slow.dictation.end()
        await slow.waitForRecoveryVerification()
        precondition(probe.delivered.last == "Segment5", "Dictation inserted raw text instead of waiting for a three-second cleanup")
        slow.shutdown()
        print("PASS: dictation waits for a three-second cleanup and inserts the cleaned text.")
    }
}
