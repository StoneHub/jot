import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    @MainActor static func checkOptionalIntelligence(directory: URL) async throws {
        for availability in CleanupAvailability.allCases {
            let probe = Probe()
            probe.deliveryFails = false
            let store = try TranscriptStore(directory: directory.appendingPathComponent("optional-\(availability.rawValue)"))
            let service = SpeechService(dependencies: .init(
                infer: { _, job, _ in probe.infer(job) },
                deliver: { _, text in try probe.deliver(text) }, now: { probe.now },
                cleanup: { cleaner, texts, timeout in
                    await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { _ in
                        preconditionFailure("Opted-out or unavailable Apple Intelligence was invoked")
                    })
                }, intelligenceAvailability: { availability }))
            service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
            service.keepAudioForSpeakerPass = false
            // Available but opted out; unavailable with saved opt-in preferences. Neither may generate.
            service.cleanUpDictation = availability != .available
            service.cleanUpTranscriptions = availability != .available
            service.suggestionsEnabled = availability != .available
            service.beginRecoveryVerification(store: store, startedAt: probe.now)
            precondition(!service.canRequestSuggestion, "Disabled or unavailable suggestions were allowed")
            precondition(service.cleanupAvailability == availability, "Settings lost the availability reason")
            service.dictation.begin()
            do {
                _ = try await service.dictation.savedDictationForReview()
                preconditionFailure("Review opened an unfinished hold")
            } catch {}
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(1), count: 48_000), at: probe.now)
            service.dictation.end()
            await service.waitForRecoveryVerification()
            precondition(probe.delivered == ["segment1"], "Basic dictation depended on Apple Intelligence")
            probe.deliveryFails = true
            service.dictation.begin()
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(2), count: 48_000), at: probe.now)
            service.dictation.end()
            await service.waitForRecoveryVerification()
            service.pause()
            while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
            let before = try store.latestRecoverableDictationAttempt()
            let reviewed = try await service.dictation.savedDictationForReview()
            let after = try store.latestRecoverableDictationAttempt()
            precondition(reviewed?.text == "segment2" && reviewed == before && before == after,
                         "Paused review changed or lost saved dictation")
            precondition(service.isPaused && !service.capture.running && probe.delivered == ["segment1"],
                         "Review restarted capture or inserted saved speech")
            service.shutdown()
        }
        print("PASS: Apple Intelligence opt-out and every unavailable reason preserve dictation, raw text and paused read-only recovery without generation.")
    }
}
