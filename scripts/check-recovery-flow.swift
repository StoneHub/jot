import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import JotEngine
import SQLite3

/// Builds as the separate JotRecoveryChecks tool. Exercises the real speech
/// controller with an isolated SQLite store, synthetic audio and delivery.
/// It never starts the microphone, shortcut listener, app UI, or local socket.
/// This file holds the entry point and shared probes; the checks themselves live
/// by topic in scripts/recovery-checks/.
@main
struct RecoveryFlowChecks {
    @MainActor final class Probe {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var deliveryFails = true
        var delivered: [String] = []
        var attempts = 0
        var chunks: [Double] = []
        var failFinal = false
        var microphoneChecks = 0
        var intelligenceChecks = 0
        var microphoneAuthorization: AVAuthorizationStatus = .authorized
        var intelligenceAvailability: CleanupAvailability = .notEnabled

        func infer(_ job: AudioJob) -> SpeechOutput {
            guard !job.samples.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
            let duration = AudioClock.seconds(samples: job.samples.count)
            chunks.append(duration)
            let text = "segment\(Int(job.samples.first ?? 0))"
            let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                startSeconds: job.offset, endSeconds: job.offset + duration,
                text: text, mode: "ambient")
            return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0.001,
                wordsByTranscript: [row.id: [.init(text: text, start: 0, end: duration, probabilities: [])]])
        }

        func deliver(_ text: String) throws -> DictationInput.DeliveryResult {
            attempts += 1
            if deliveryFails { throw DictationInput.InputError.targetChanged }
            delivered.append(text)
            return .init(verified: true, path: "synthetic", outcome: "verified",
                targetApp: "synthetic-test", targetPID: 0, role: "AXTextField", subrole: nil)
        }
    }

    /// Owes silence on the wall clock like a real microphone: whatever the service has not drained within `holdingSeconds` is dropped, as MicrophoneCapture's queue limit drops what it cannot hold.
    final class ClockedMicrophone: MicrophoneSource, @unchecked Sendable {
        private let holding: Int
        private var began: ContinuousClock.Instant?
        private var delivered = 0
        init(holdingSeconds: Double) { holding = AudioClock.samples(seconds: holdingSeconds) }
        var running: Bool { began != nil }
        var bufferedSampleCount: Int { 0 }
        func setInput(uid: String?) throws {}
        func setInputForNextStart(uid: String?) {}
        func shouldIgnoreConfigurationChange() -> Bool { false }
        func start() throws {
            began = .now
            delivered = 0
        }
        func stop() { began = nil }
        func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
            guard let began else { return ([], 0, Date(), 0) }
            let owed = AudioClock.samples(seconds: began.duration(to: .now) / .seconds(1)) - delivered
            delivered += owed
            let kept = min(owed, holding)
            return (Array(repeating: 0, count: kept), owed - kept, Date(), 0)
        }
    }

    @MainActor static func main() async throws {
        ShortcutInputChecks.run()
        if let flag = CommandLine.arguments.firstIndex(of: "--quiet-cpu") {
            try await profileQuietListening(CommandLine.arguments.dropFirst(flag + 1).map { URL(fileURLWithPath: $0) })
            return
        }
        if CommandLine.arguments.contains("--listening-overhead") {
            try await measureListeningOverhead()
            return
        }
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(90))
            FileHandle.standardError.write(Data("Recovery checks timed out.\n".utf8))
            exit(2)
        }
        defer { watchdog.cancel() }
        if CommandLine.arguments.contains("--dictation-model") { try await checkDictationProse(); return }
        if CommandLine.arguments.contains("--capture") { try await CaptureFlowChecks.run(); return }
        checkCPUReadout()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-recovery-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let probe = Probe()
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) },
            deliver: { _, text in try probe.deliver(text) },
            now: { probe.now }))
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        service.library.showLive(service.timeline.activeSessionID)

        service.dictation.begin()
        for index in 1...25 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
            let count = try store.session(id: service.timeline.activeSessionID!).count
            precondition(count == index, "Speech was not persisted while the hold was still active")
            precondition(service.library.live.paragraphs.last?.text.hasSuffix("segment\(index)") == true, "Live did not add the row when it was saved")
        }
        precondition(probe.chunks.allSatisfy { $0 <= 3 }, "Recognition still waits for a large audio block")
        try await libraryMatchesStore(service, store, "25 dictation blocks")
        service.dictation.end()
        await service.waitForRecoveryVerification()
        let expected = (1...25).map { "segment\($0)" }.joined(separator: " ")
        let retained = try store.latestRecoverableDictationAttempt()
        precondition(retained?.text == expected, "A 75-second hold lost recognized words")
        precondition(probe.attempts == 1 && probe.delivered.isEmpty, "Failed delivery was retried automatically")
        let reopened = try TranscriptStore(directory: directory)
        let reopenedAttempt = try reopened.latestRecoverableDictationAttempt()
        precondition(reopenedAttempt?.text == expected, "Saved dictation did not survive reopening storage")
        print("PASS: 75-second hold persisted all 25 chunks before release; failed delivery retained across store reopen.")
        let fullRead = await service.library.sessionParagraphs(service.timeline.activeSessionID!).map(\.text)
        precondition(service.library.live.paragraphs.map(\.text) == fullRead, "Live differs from a full read of the session")
        precondition(service.library.live.paragraphs.contains { $0.mode == "dictation" }, "Live did not show the saved dictation")
        print("PASS: Live adds each saved row and the held dictation as they are saved, matching a full read.")

        // Double-tap discards its short holds; saved review is read-only and never inserts room speech.
        service.dictation.begin(); service.dictation.cancelTap()
        service.dictation.begin(); service.dictation.cancelTap()
        let reviewed = try await service.dictation.savedDictationForReview()
        precondition(reviewed?.text == expected && probe.delivered.isEmpty, "Review lost or inserted the saved hold")
        let reviewedAgain = try await service.dictation.savedDictationForReview()
        precondition(reviewedAgain == reviewed, "Review consumed saved text")
        print("PASS: short taps preserve earlier failed dictation; review returns it without insertion or consumption.")

        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(26), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()

        // Pause must save the sub-chunk tail rather than discard it.
        probe.now += 0.5
        service.ingestRecoveryVerification(samples: Array(repeating: Float(27), count: 8_000), at: probe.now)
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        let finalRows = try store.session(id: service.timeline.activeSessionID!)
        precondition(finalRows.contains(where: { $0.text == "segment27" }), "Pause discarded the unfinished tail")
        precondition(service.lifecycle.phase == .ready && service.modelsLoaded && service.isPaused, "Pause did not keep the models loaded")
        print("PASS: Pause persisted the final half-second and kept the models loaded.")

        try await checkFailureAndCleanup(directory: directory)
        try await checkDictationTimings(directory: directory)
        try await checkFillerOnlyBlocksAreNotSaved(directory: directory)
        try await checkSingleWordDictation(directory: directory)
        try await checkLiveFollowsEdits(directory: directory)
        try await checkInterruptedHold(directory: directory)
        try await checkOptionalIntelligence(directory: directory)
        for failed in [false, true] {
            let inactive = SpeechService()
            let token = inactive.lifecycle.beginStart()!
            if failed { _ = inactive.lifecycle.finishStart(token, succeeded: false) }
            inactive.pause()
            while inactive.pauseRequested { try await Task.sleep(for: .milliseconds(5)) }
            precondition(inactive.transcriber.isIdle, "Pause enqueued audio while nothing was captured")
            inactive.shutdown()
        }
        print("PASS: Pause during model preparation or failed preparation does not enqueue unprocessable final audio.")

        try await checkQuietAndStall(directory: directory)
        try await checkCPUReadoutWhileListening(directory: directory)
        try await checkIdleRedraws(directory: directory)
        try await checkHousekeepingCadence(directory: directory)
        try await checkSpeakerPassKeepsCleanup(directory: directory)
        try await checkRelabelsTakeTurns(directory: directory)
        try await checkControlsRedrawWhenWorkEnds(directory: directory)
        try await checkSpeakerPassKeepsMainFree(directory: directory)
        try await checkTuningAudio(directory: directory)
        try await checkLibraryReadsStayResponsive(directory: directory)
        try await checkDeletionFailurePreservesLateRecognition(directory: directory)
        try await CaptureFlowChecks.run()
        if CommandLine.arguments.contains("--cleanup-model") { try await checkPhraseCleanupModel() }

        if let flag = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.count > flag + 1 {
            try await checkDictationProse()
            try await checkRealRecognition(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        print("Recovery controller checks passed. These checks do not establish physical Fn or cross-app Accessibility behavior.")
    }

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

    /// The process's CPU time from getrusage, which ps agrees with.
    static func kernelCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Keeps one core busy for half a second and compares the CPU readout with the kernel's count.
    static func checkCPUReadout() {
        let sampler = ResourceSampler()
        _ = sampler.sample()
        let began = ProcessInfo.processInfo.systemUptime
        let kernelBegan = kernelCPUSeconds()
        while ProcessInfo.processInfo.systemUptime - began < 0.5 {}
        let readout = sampler.sample().processCPUPercent
        let expected = (kernelCPUSeconds() - kernelBegan) / (ProcessInfo.processInfo.systemUptime - began) * 100
        precondition(abs(readout - expected) < expected / 10, "CPU readout \(readout)% disagrees with the kernel's \(expected)%")
        print("PASS: the CPU readout matches the kernel's count while the process keeps a core busy.")
    }

    /// A finished recognition samples CPU for `jot diagnostics`, and the readout must still count that recognition's CPU. Each readout covers the time since the one before it, so weighting each by its interval adds up the CPU they report together.
    @MainActor static func checkCPUReadoutWhileListening(directory: URL) async throws {
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("cpu"))
        let service = SpeechService(dependencies: .init(infer: { _, _, _ in
            let began = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - began < 0.2 {}
            return SpeechOutput(transcripts: [], text: "", processingSeconds: 0.2)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        var readouts: [(snapshot: ResourceSnapshot, kernelSeconds: Double)] = []
        let watcher = service.resourceReadout.$snapshot.dropFirst().sink { readouts.append(($0, kernelCPUSeconds())) }
        defer { watcher.cancel() }
        // Digital silence in real time: every 0.8 seconds the silence closes a chunk, and its recognition keeps a core busy for 0.2 seconds. The tick publishes the readout once a second.
        for _ in 1...16 {
            probe.now += 0.2
            service.ingestRecoveryVerification(samples: Array(repeating: 0, count: 3_200), rms: 0, at: probe.now)
            service.tickRecoveryVerification()
            await service.waitForRecoveryVerification()
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(readouts.count == 4, "The tick published the CPU readout \(readouts.count) times in 16 ticks, not 4")
        let span = readouts[3].snapshot.uptimeSeconds - readouts[0].snapshot.uptimeSeconds
        let reportedSeconds = zip(readouts, readouts.dropFirst()).reduce(0.0) { total, pair in
            total + pair.1.snapshot.processCPUPercent / 100 * (pair.1.snapshot.uptimeSeconds - pair.0.snapshot.uptimeSeconds)
        }
        let readout = reportedSeconds / span * 100
        let expected = (readouts[3].kernelSeconds - readouts[0].kernelSeconds) / span * 100
        precondition(abs(readout - expected) < expected / 10, "Over three readouts of listening the CPU readout said \(readout)%, the kernel \(expected)%")
        print(String(format: "PASS: while each recognition keeps a core busy for 0.2 seconds, three CPU readouts in a row match the kernel's count (%.1f%% against %.1f%%).", readout, expected))
    }

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

    /// Live reads its session once and then only adds rows and cleaned text, so every other edit must make it read the session again: a speaker name from the sheet or the socket, a new paragraph pause, and a delete.
    @MainActor static func checkLiveFollowsEdits(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let folder = directory.appendingPathComponent("live-edits")
        let store = try TranscriptStore(directory: folder)
        // Rows 1 and 2 are one speaker's, rows 3 to 5 another's. Each row ends two seconds before the next starts, so the paragraph pause decides whether a speaker's rows join.
        // Block 4 also hands back a row the store refuses, after its first row is saved.
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                guard let first = job.samples.first, first > 0 else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
                let index = Int(first)
                let text = "segment\(index)"
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset, endSeconds: job.offset + 1,
                    text: text, speakerID: index <= 2 ? "speaker-1" : "speaker-2", mode: "ambient")
                let refused = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset + 2, endSeconds: job.offset + 1,
                    text: "refused", mode: "ambient")
                return SpeechOutput(transcripts: index == 4 ? [row, refused] : [row], text: text, processingSeconds: 0)
            }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        service.speakers.peopleStore = try PeopleStore(sharing: store)
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let id = service.timeline.activeSessionID!
        service.library.showLive(id)
        func speak(_ index: Int) async {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        func shown() -> [String] {
            service.library.live.paragraphs.map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }
        func fullRead() async -> [String] {
            await service.library.sessionParagraphs(id).map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }

        func checkShown(_ message: String, condition: () -> Bool = { true }) async {
            await service.library.waitForReads()
            let expected = await fullRead()
            precondition(condition() && shown() == expected, message)
        }

        for index in 1...4 {
            await speak(index)
        }
        await checkShown("Live lost a saved row when the next row of its block could not be saved", condition: { shown().last == "Speaker 2: segment4" })
        try await libraryMatchesStore(service, store, "a block whose second row could not be saved")
        let revision = service.library.live.revision
        service.library.showLive(id)
        precondition(service.library.live.revision == revision, "Live read its session again when it was shown a second time")
        service.dictation.begin()
        await speak(5)
        service.dictation.end()
        await service.waitForRecoveryVerification()
        await checkShown("Live did not show the session as saved", condition: { service.library.live.paragraphs.contains { $0.mode == "dictation" } })
        try await libraryMatchesStore(service, store, "a dictation held while listening")

        await service.labelSpeaker(session: id, speaker: "speaker-1", name: "Ada")
        await checkShown("Live kept the old name after a speaker was named", condition: { shown().contains("Ada: segment1") })
        service.notice = ""
        // A voice of zeros cannot be remembered. The name is saved before that fails.
        await service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace", voice: [0, 0])
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty, "Remembering a voice of zeros did not fail")
        await checkShown("Live kept the old name when remembering the voice failed", condition: { shown().contains("Grace: segment3") })
        let request = try JSONSerialization.data(withJSONObject: ["method": "speakers.label", "params": ["sessionID": id, "speakerID": "speaker-1", "name": "Ada King"]])
        let reply = try JSONSerialization.jsonObject(with: await service.handle(request)) as? [String: Any]
        precondition(reply?["ok"] as? Bool == true, "speakers.label failed over the socket")
        await checkShown("Live kept the old name after speakers.label", condition: { shown().contains("Ada King: segment1") })

        service.tuning.paragraphPause = 2.5
        await checkShown("Live kept the old paragraphs after a new paragraph pause", condition: { shown().contains("Ada King: segment1 segment2") })
        let paused = service.library.live.revision
        service.tuning.speakerConfidence = 0.8
        precondition(service.library.live.revision == paused, "Live read its session again after a setting it does not group by")
        try await service.deleteHistoryCard(service.library.history.first!)
        await checkShown("Live still showed a deleted row", condition: { !service.library.live.paragraphs.contains { $0.mode == "dictation" } })

        // Hiding the names table makes the session read fail. Live still moves to the session, so a row saved next shows, and the next reload reads the whole session.
        service.library.showLive(nil)
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.library.showLive(id)
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty && service.library.live.paragraphs.isEmpty, "Reading the session without its names table did not fail")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        await speak(6)
        precondition(service.library.live.paragraphs.map(\.text) == ["segment6"], "Live dropped a row saved after a failed read")
        await service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace Hopper")
        await checkShown("Live did not read the session again after a failed read", condition: { shown().contains("Ada King: segment1 segment2") })

        // A reload of the shown session that fails keeps what Live shows, and the next show reads the session again.
        let kept = shown()
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.tuning.paragraphPause = 1.5
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty && shown() == kept, "Live dropped its rows when a reload of the shown session failed")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        service.library.showLive(id)
        await checkShown("Live did not read the session again after a failed reload", condition: { shown().contains("Ada King: segment1") })
        await speak(7)
        try await libraryMatchesStore(service, store, "speaker names, a delete and failed reads, then a block")
        print("PASS: Live keeps a row saved before a failed one, and reads its session again after a speaker name, a failed voice, speakers.label, a new paragraph pause, and a delete, but not after another setting or a second show.")
        print("PASS: after a failed switch Live shows the rows saved next; after a failed reload it keeps its rows; either way the next read retries.")
        print("PASS: recent rows, Sessions and Dictations take in each block's saved rows and cleaned text without a full read, and match one.")
        // A service reads its tuning from the settings when it is made, so later checks start from the defaults again.
        service.tuning = TranscriptionTuning()
        await service.library.waitForReads()
    }

    /// Recent rows, Sessions and Dictations fold in each block's saved rows and each phrase's cleaned text instead of reading the store again; what they hold must be what a full read returns.
    @MainActor static func libraryMatchesStore(_ service: SpeechService, _ store: TranscriptStore, _ step: String) async throws {
        await service.library.waitForReads()
        let recent = try store.recent(limit: 20), sessions = try store.sessions(limit: 200)
        precondition(service.library.recent == recent, "Recent rows differ from a full read after \(step)")
        precondition(service.library.sessions == sessions, "Sessions differ from a full read after \(step)")
        let history = service.library.history, count = service.library.dictationCount, more = service.library.hasMoreHistory
        service.library.refreshHistory()
        await service.library.waitForReads()
        precondition(service.library.history == history && service.library.dictationCount == count && service.library.hasMoreHistory == more,
            "Dictations differ from a full read after \(step)")
    }

    /// Renames a table of a store's database over a second connection, so the store's next query of it fails, or works again.
    static func renameTable(_ name: String, to newName: String, in folder: URL) {
        var db: OpaquePointer?
        let path = folder.appendingPathComponent("transcripts.sqlite3").path
        precondition(sqlite3_open(path, &db) == SQLITE_OK, "Could not open the store's database")
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        precondition(sqlite3_exec(db, "ALTER TABLE \(name) RENAME TO \(newName)", nil, nil, nil) == SQLITE_OK, "Could not rename \(name)")
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

    /// Quiet and a stalled microphone are measured on the injected clock, so a tick at a later fake time reaches them without waiting.
    @MainActor static func checkQuietAndStall(directory: URL) async throws {
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("quiet"))
        var dependencies = SpeechServiceDependencies(infer: { _, job, _ in
            job.samples.contains(where: { $0 != 0 }) ? probe.infer(job) : SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now })
        // Starting a meeting asks for the microphone before it finds listening already on.
        dependencies.microphoneAuthorization = { .authorized }
        let service = SpeechService(dependencies: dependencies)
        service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false
        service.newSessionAfterSilence = 10
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        func speak() async {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: 1, count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        // Silent audio keeps arriving through the quiet, so the stall check leaves the tick to the quiet limit.
        func quiet(for seconds: Double) async {
            probe.now += seconds
            service.ingestRecoveryVerification(samples: Array(repeating: 0, count: 1_600), rms: 0, at: probe.now)
            await service.waitForRecoveryVerification()
            service.tickRecoveryVerification()
        }

        await speak()
        let first = service.timeline.activeSessionID
        await quiet(for: 300)
        precondition(service.timeline.activeSessionID == first, "A new session started before ten minutes of quiet")
        await quiet(for: 301)
        precondition(service.timeline.activeSessionID != first, "Ten minutes of quiet did not start a new session")
        print("PASS: ten minutes of quiet after speech starts a new session on the next tick; five minutes does not.")

        await service.startMeeting("Standup")
        precondition(service.meetingTitle == "Standup", "The meeting did not start: \(service.notice)")
        await speak()
        let meeting = service.timeline.activeSessionID
        await quiet(for: 601)
        precondition(service.timeline.activeSessionID == meeting, "A named meeting started a new session after ten minutes of quiet")
        print("PASS: a named meeting keeps its session through the same quiet.")

        probe.now += 5
        service.tickRecoveryVerification()
        precondition(service.pauseRequested && service.notice.hasPrefix("Microphone stopped delivering audio"), "Five seconds without microphone audio did not pause")
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!service.ambientEnabled && service.modelsLoaded, "An automatic pause unloaded the models")
        print("PASS: five seconds without microphone audio pauses automatically, with the models kept.")
    }

    /// Resource samples must refresh their readouts without invalidating every screen that observes the service.
    @MainActor static func checkIdleRedraws(directory: URL) async throws {
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("idle"))
        var recognitions = 0
        // The timer tick drains the microphone itself, as in the app, so a chunk cut by a drain is still in the queue when the same tick does its once-a-second status work.
        let microphone = ConstantMicrophone(seconds: 0.2, value: 0)
        var dependencies = SpeechServiceDependencies(infer: { _, _, _ in
            recognitions += 1
            return SpeechOutput(transcripts: [], text: "", processingSeconds: 0.05)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now })
        dependencies.makeMicrophone = { microphone }
        let service = SpeechService(dependencies: dependencies)
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        var changes = 0
        // TranscriptView observes the service, the library and the timeline; a publish from any of them redraws the whole window.
        let counter = service.objectWillChange.merge(with: service.library.objectWillChange, service.timeline.objectWillChange).sink { changes += 1 }
        defer { counter.cancel() }
        // Five seconds of digital silence, drained and ticked every 0.2 seconds like the timer. Every 0.8 seconds the silence closes a chunk, and recognition finds no speech in it. The status second lands on a chunk close at 3.2 seconds, as it does about every four seconds of quiet in the app.
        for _ in 1...25 {
            probe.now += 0.2
            microphone.lastAudio = probe.now
            service.tickRecoveryVerification()
            await service.waitForRecoveryVerification()
        }
        precondition(recognitions == 6, "Five seconds of silence ran \(recognitions) recognitions, not six")
        precondition(changes == 0, "Resource-only ticks told the whole window to redraw \(changes) times")
        print("PASS: resource-only ticks and six recognitions that find no speech do not invalidate the whole window, even when the status second lands on a chunk close.")

        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        changes = 0
        var readouts = 0
        let meters = service.resourceReadout.$snapshot.dropFirst().sink { _ in readouts += 1 }
        defer { meters.cancel() }
        for _ in 1...6 {
            probe.now += 60
            service.tickRecoveryVerification()
        }
        precondition(readouts == 6, "Paused CPU and memory meters stopped refreshing")
        precondition(changes == 0, "Paused resource ticks told the whole window to redraw \(changes) times")
        precondition(service.resources.valid, "The diagnostic snapshot no longer sees the current resource readout")
        print("PASS: six minute-spaced paused ticks refresh the resource meters without invalidating the whole window.")
    }

    /// Fast audio/stall ticks remain independent of slow capability housekeeping.
    /// The same immediate refresh used on foreground activation updates cached UI
    /// state; starting a hold still checks microphone authorization at point of use.
    @MainActor static func checkHousekeepingCadence(directory: URL) async throws {
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("housekeeping"))
        let microphone = ConstantMicrophone(seconds: 0.2, value: 0)
        var dependencies = SpeechServiceDependencies(infer: { _, job, _ in
            probe.chunks.append(AudioClock.seconds(samples: job.samples.count))
            return SpeechOutput(transcripts: [], text: "", processingSeconds: 0.001)
        },
            deliver: { _, text in try probe.deliver(text) }, now: { probe.now })
        dependencies.makeMicrophone = { microphone }
        dependencies.microphoneAuthorization = {
            probe.microphoneChecks += 1
            return probe.microphoneAuthorization
        }
        dependencies.intelligenceAvailability = {
            probe.intelligenceChecks += 1
            return probe.intelligenceAvailability
        }
        let service = SpeechService(dependencies: dependencies)
        defer { service.shutdown() }
        precondition(service.tickInterval == 60, "Paused housekeeping still wakes more often than once a minute")
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        precondition(service.tickInterval == 0.2, "Listening no longer drains audio five times a second")
        // The first tick establishes the background check, then fast ticks must
        // not repeat authorization/Apple Intelligence queries before 60 seconds.
        microphone.lastAudio = probe.now
        service.tickRecoveryVerification()
        await service.waitForRecoveryVerification()
        let microphoneChecks = probe.microphoneChecks, intelligenceChecks = probe.intelligenceChecks
        for _ in 1...59 {
            probe.now += 1
            microphone.lastAudio = probe.now
            service.tickRecoveryVerification()
            await service.waitForRecoveryVerification()
        }
        precondition(service.ambientEnabled && !service.pauseRequested, "Capability checks did not remain on the active listening path")
        precondition(probe.microphoneChecks == microphoneChecks && probe.intelligenceChecks == intelligenceChecks,
                     "One-second active stats still poll capabilities")
        probe.now += 1
        microphone.lastAudio = probe.now
        service.tickRecoveryVerification()
        await service.waitForRecoveryVerification()
        precondition(probe.microphoneChecks == microphoneChecks + 1 && probe.intelligenceChecks == intelligenceChecks + 1,
                     "Background capabilities were not refreshed after one minute")
        probe.microphoneAuthorization = .denied
        probe.intelligenceAvailability = .available
        service.refreshCapabilities()
        precondition(service.micPermission == .denied && service.cleanupAvailability == .available,
                     "Foreground capability refresh did not update permissions/Apple Intelligence immediately")
        probe.microphoneAuthorization = .authorized
        let granted = await service.requestMic()
        precondition(granted, "A request waited for background permission polling")
        precondition(service.micPermission == .authorized, "Explicit microphone request retained stale permission state")
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        precondition(service.tickInterval == 60 && service.isPaused && service.modelsLoaded,
                     "Pause did not restore minute housekeeping while retaining prepared models")
        await service.waitForRecoveryVerification()
        let recognitions = probe.chunks.count
        probe.now += 60
        service.tickRecoveryVerification()
        precondition(service.transcriber.isIdle && probe.chunks.count == recognitions && !service.capture.running,
                     "Delayed paused housekeeping started capture or recognition work")
        print("PASS: paused housekeeping is 60 seconds, listening drain remains 0.2 seconds, capabilities check once per minute, and foreground/request revalidation is immediate.")
    }

    /// What a screen that observes only the service shows for Install Update and the shortcut button. SwiftUI reads a screen's values on a later turn of the main actor than objectWillChange, so a change that no publish follows stays on screen.
    @MainActor final class ServiceScreen {
        private(set) var update: Bool
        private(set) var shortcut: Bool
        private let service: SpeechService
        private var redraws: AnyCancellable?
        init(_ service: SpeechService) {
            self.service = service
            update = service.canInstallUpdate; shortcut = service.canChangeShortcut
            redraws = service.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.draw() }
            }
        }
        private func draw() { update = service.canInstallUpdate; shortcut = service.canChangeShortcut }
        /// Lets the redraws the publishes so far scheduled run.
        func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Work that ends with no other change on the service still redraws the controls that wait for it: phrase cleanup that outlasts Pause, a released dictation whose insertion is discarded, and a file diagnostic.
    @MainActor static func checkControlsRedrawWhenWorkEnds(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let cleanupGate = CleanupGate(), deliveryGate = CleanupGate()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("controls"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) },
            deliver: { _, text in
                try await deliveryGate.pass()
                return try probe.deliver(text)
            },
            now: { probe.now },
            cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { texts in
                    try await cleanupGate.pass()
                    return texts.map { $0.capitalized }
                })
            }, intelligenceAvailability: { .available }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpDictation = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let screen = ServiceScreen(service)

        // A released hold whose Dictations card is deleted while its text is being inserted.
        service.dictation.begin()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(1), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        deliveryGate.close()
        service.dictation.end()
        while !deliveryGate.holding { try await Task.sleep(for: .milliseconds(1)) }
        try await screen.settle()
        precondition(!screen.shortcut, "The shortcut button stayed enabled while a released dictation was pending")
        // Deleting the card discards the attempt's rows first, as here.
        service.dictation.discard(ids: [service.dictation.currentAttempt!.id])
        deliveryGate.open()
        await service.waitForRecoveryVerification()
        try await screen.settle()
        // Replacement readiness is read live, as Update's wait reads it: the discard's closing library read can still be on the store queue when isPending's redraw lands, and its end publishes on the library, not the service. In the app, listening keeps replacement blocked through any dictation anyway.
        precondition(!service.dictation.isPending && screen.shortcut && service.canInstallUpdate, "The shortcut and replacement readiness stayed disabled after a dictation discarded during insertion")
        print("PASS: a released dictation discarded during insertion enables the shortcut and replacement readiness again.")

        // What speech.transcribe_file sets and clears around a file diagnostic.
        service.diagnosticActive = true
        try await screen.settle()
        precondition(!screen.update, "App replacement stayed allowed during a file diagnostic")
        service.diagnosticActive = false
        try await screen.settle()
        precondition(screen.update, "App replacement stayed blocked after a file diagnostic")
        print("PASS: app replacement waits for a file diagnostic to end.")

        // Phrase cleanup still running when Pause finishes.
        service.cleanUpTranscriptions = true
        cleanupGate.close()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(2), count: 48_000), at: probe.now)
        service.flushRecoveryVerification()
        while !cleanupGate.holding { try await Task.sleep(for: .milliseconds(1)) }
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        try await screen.settle()
        precondition(service.cleanup.isRunning && !screen.update, "App replacement was allowed while cleanup was still running after Pause")
        var updateFinished = false
        let update = Task { try await service.prepareForUpdate(); updateFinished = true }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!updateFinished, "Update skipped pending cleanup")
        cleanupGate.open()
        try await update.value
        service.cancelUpdatePreparation()
        try await screen.settle()
        precondition(service.canInstallUpdate && screen.update, "Replacement stayed blocked after cleanup that outlasted Pause finished")
        print("PASS: app replacement waits for cleanup that outlasts Pause.")
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
