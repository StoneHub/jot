import AppKit
import Foundation
import JotCore
import FluidAudio

/// Builds as the separate JotRecoveryChecks tool. Exercises the real speech
/// controller with an isolated SQLite store, synthetic audio and delivery.
/// It never starts the microphone, shortcut listener, app UI, or local socket.
@main
struct RecoveryFlowChecks {
    @MainActor final class Probe {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var deliveryFails = true
        var delivered: [String] = []
        var attempts = 0
        var chunks: [Double] = []
        var failFinal = false

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

    @MainActor static func main() async throws {
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(90))
            FileHandle.standardError.write(Data("Recovery checks timed out.\n".utf8))
            exit(2)
        }
        defer { watchdog.cancel() }
        checkRecognitionCommitWindow()
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

        service.beginDictation()
        for index in 1...25 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
            let count = try store.session(id: service.activeSessionID!).count
            precondition(count == index, "Speech was not persisted while the hold was still active")
        }
        precondition(probe.chunks.allSatisfy { $0 <= 3 }, "Recognition still waits for a large audio block")
        service.endDictation()
        await service.waitForRecoveryVerification()
        let expected = (1...25).map { "segment\($0)" }.joined(separator: " ")
        let retained = try store.latestRecoverableDictationAttempt()
        precondition(retained?.text == expected, "A 75-second hold lost recognized words")
        precondition(probe.attempts == 1 && probe.delivered.isEmpty, "Failed delivery was retried automatically")
        let reopened = try TranscriptStore(directory: directory)
        let reopenedAttempt = try reopened.latestRecoverableDictationAttempt()
        precondition(reopenedAttempt?.text == expected, "Saved dictation did not survive reopening storage")
        print("PASS: 75-second hold persisted all 25 chunks before release; failed delivery retained across store reopen.")

        // A double-tap creates two short intents before requesting recovery. Neither
        // may replace the earlier failed attempt or erase the listening timeline.
        service.beginDictation(); service.cancelTapDictation()
        service.beginDictation(); service.cancelTapDictation()
        probe.deliveryFails = false
        service.recoverRecentDictation()
        await service.waitForRecoveryVerification()
        precondition(probe.delivered == [expected], "Recovery did not insert the full failed attempt exactly once")
        let pendingAfterDelivery = try store.latestRecoverableDictationAttempt()
        precondition(pendingAfterDelivery == nil, "Verified delivery remained pending")
        print("PASS: two short taps preserve the failed attempt; explicit recovery delivers it once.")

        service.recoveryLookbackSeconds = 30
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(26), count: 48_000), at: probe.now)
        // Recover without waiting: the command must include queued/in-flight speech.
        service.recoverRecentDictation()
        await service.waitForRecoveryVerification()
        let recent = probe.delivered.last ?? ""
        precondition(recent.contains("segment26"), "Recovery omitted the newest pending speech")
        precondition(!recent.split(separator: " ").contains("segment1"), "Lookback ignored the configured start boundary")
        print("PASS: recent recovery includes pending recognition and respects the time window.")

        // Pause must save the sub-chunk tail rather than discard it.
        probe.now += 0.5
        service.ingestRecoveryVerification(samples: Array(repeating: Float(27), count: 8_000), at: probe.now)
        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        let finalRows = try store.session(id: service.activeSessionID!)
        precondition(finalRows.contains(where: { $0.text == "segment27" }), "Pause discarded the unfinished tail")
        print("PASS: Pause persisted the final half-second before unloading.")

        try await checkFailureAndCleanup(directory: directory)
        for failed in [false, true] {
            let inactive = SpeechService()
            let token = inactive.lifecycle.beginStart()!
            if failed { _ = inactive.lifecycle.finishStart(token, succeeded: false) }
            inactive.pause()
            while inactive.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(5)) }
            inactive.shutdown()
        }
        print("PASS: Pause during model preparation or failed preparation does not enqueue unprocessable final audio.")

        try await checkQuietAndStall(directory: directory)
        try await checkCPUReadoutWhileListening(directory: directory)
        try await checkIdleRedraws(directory: directory)
        try await CaptureFlowChecks.run()
        if CommandLine.arguments.contains("--cleanup-model") { try await checkPhraseCleanupModel() }

        if let flag = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.count > flag + 1 {
            try await checkRealRecognition(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        print("Recovery controller checks passed. These checks do not establish physical Fn or cross-app Accessibility behavior.")
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
            while try store.session(id: service.activeSessionID!).count < index {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let before = try store.session(id: service.activeSessionID!).map(\.text)
        precondition(before == fragments, "Recognition did not publish before phrase cleanup")
        await service.waitForRecoveryVerification()
        let after = try store.session(id: service.activeSessionID!).map(\.text).joined(separator: " ")
        precondition(after == "I think we could get faster output to the live view.", "Real model did not clean the complete phrase: \(after)")
        precondition(service.recoveryDiagnostics["cleanupRequested"] as? Int == 1, "Transport fragments became separate cleanup requests")
        service.shutdown()
        print("PASS: actual Foundation Model cleans the three published fragments as one phrase and persists their replacement.")
    }

    static func checkRecognitionCommitWindow() {
        var window = RecognitionCommitWindow(contextSeconds: 2, sampleRate: 10)
        let first = window.plan(sessionID: "a", offset: 0,
            newSamples: Array(repeating: 1, count: 30), isFinal: false)
        precondition(first.samples.count == 30 && first.commitStart == 0 && first.commitEnd == 1)
        let firstWords = window.newWords(from: [
            WordTiming(word: "Echo", startTime: 0.8, endTime: 1.0)
        ], for: first)
        precondition(firstWords.count == 1)
        window.commit(first, words: firstWords)

        let second = window.plan(sessionID: "a", offset: 3,
            newSamples: Array(repeating: 2, count: 30), isFinal: false)
        let seamWords = window.newWords(from: [
            // Same acoustic word moved across the commit cursor on a re-decode.
            WordTiming(word: "echo", startTime: 0.85, endTime: 1.15),
            // A genuine adjacent repetition has a distinct, non-overlapping time.
            WordTiming(word: "echo", startTime: 1.16, endTime: 1.34)
        ], for: second)
        precondition(seamWords.count == 1 && seamWords[0].startTime == 1.16,
            "Commit seam duplicate handling removed genuine repeated speech")
        window.commit(second, words: seamWords)

        let third = window.plan(sessionID: "a", offset: 6,
            newSamples: Array(repeating: 3, count: 30), isFinal: false)
        precondition(third.samples.count == 70, "Recognition context exceeded or lost the seven-second bound")
        precondition(!third.contains(start: 5, end: 5), "Non-final commit intervals must be half-open")
        window.commit(third)

        let final = window.plan(sessionID: "a", offset: 9, newSamples: [], isFinal: true)
        precondition(final.samples.count == 40 && final.commitStart == 7 && final.commitEnd == 9,
            "An empty final job did not expose the retained two-second tail")
        window.commit(final)
        let afterFinal = window.plan(sessionID: "a", offset: 9,
            newSamples: Array(repeating: 4, count: 30), isFinal: false)
        precondition(afterFinal.samples.count == 30 && afterFinal.bufferOffset == 9,
            "Final commit did not reset recognition context")
        window.commit(afterFinal)

        let newSession = window.plan(sessionID: "b", offset: 12,
            newSamples: Array(repeating: 5, count: 30), isFinal: false)
        precondition(newSession.samples.count == 30 && newSession.bufferOffset == 12,
            "Session rotation retained prior recognition audio")
        window.commit(newSession)
        let discontinuity = window.plan(sessionID: "b", offset: 20,
            newSamples: Array(repeating: 6, count: 30), isFinal: false)
        precondition(discontinuity.samples.count == 30 && discontinuity.bufferOffset == 20,
            "A discontinuity retained prior recognition audio")

        // SpeechPipeline uses this same reset when a plan throws, bounding the
        // next recognition window instead of accumulating failed audio.
        window.reset()
        let afterError = window.plan(sessionID: "b", offset: 23,
            newSamples: Array(repeating: 7, count: 30), isFinal: false)
        precondition(afterError.samples.count == 30 && afterError.bufferOffset == 23,
            "An abandoned recognition plan retained failed audio")
        print("PASS: recognition windows retain bounded context, flush tails, deduplicate seams, preserve repeats, and reset at boundaries.")
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
        let watcher = service.$resources.dropFirst().sink { readouts.append(($0, kernelCPUSeconds())) }
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
        service.beginDictation()
        for index in 1...3 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        service.endDictation()
        await service.waitForRecoveryVerification()
        let partial = try store.latestRecoverableDictationAttempt()
        precondition(probe.delivered.isEmpty && partial?.hasGap == true && partial?.text == "segment1 segment3",
            "Recognition failure inserted a partial dictation as complete")
        service.disableFn()
        let afterDisable = try store.latestRecoverableDictationAttempt()
        precondition(afterDisable == partial, "Disabling shortcut deleted retained speech")

        service.beginDictation()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(4), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        probe.failFinal = true
        service.endDictation()
        await service.waitForRecoveryVerification()
        let finalFailure = try store.latestRecoverableDictationAttempt()
        precondition(probe.delivered.isEmpty && finalFailure?.hasGap == true && finalFailure?.text == "segment4",
            "An empty final barrier failed without retaining a partial attempt")
        try store.deleteDictationAttempt(id: partial!.id)
        try store.deleteDictationAttempt(id: finalFailure!.id)
        service.recoverRecentDictation()
        await service.waitForRecoveryVerification()
        let recentFailure = try store.latestRecoverableDictationAttempt()
        precondition(probe.delivered.isEmpty && recentFailure?.hasGap == true,
            "A failed recent-recovery barrier inserted partial speech without warning")
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
            }))
        cleaned.highlightTargetField = false; cleaned.muteSpeakersDuringDictation = false
        cleaned.keepAudioForSpeakerPass = false; cleaned.cleanUpTranscriptions = true
        cleaned.beginRecoveryVerification(store: cleanedStore, startedAt: probe.now)
        for index in 1...2 {
            probe.now += 3
            cleaned.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            // Each explicit quiet boundary completes a phrase. The next phrase
            // must be queued while cleanup is busy, not discarded as raw forever.
            cleaned.flushRecoveryVerification()
            while try cleanedStore.session(id: cleaned.activeSessionID!).count < index {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let raw = try cleanedStore.session(id: cleaned.activeSessionID!)
        precondition(raw.map(\.text) == ["segment1", "segment2"], "Raw text did not publish before delayed cleanup")
        await cleaned.waitForRecoveryVerification()
        let readable = try cleanedStore.session(id: cleaned.activeSessionID!)
        precondition(readable.map(\.text) == ["Segment1", "Segment2"], "Phrase cleanup dropped work while the model was busy")
        precondition(cleaned.recoveryDiagnostics["cleanupApplied"] as? Int == 2, "Cleanup outcome was not reported")
        cleaned.shutdown()
        print("PASS: raw text publishes before delayed cleanup; the next recognition completes while cleanup runs, then the first row is replaced.")

        let slowStore = try TranscriptStore(directory: directory.appendingPathComponent("dictation-cleanup"))
        let slow = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) }, deliver: { _, text in try probe.deliver(text) },
            now: { probe.now }, cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: {
                    try await Task.sleep(for: .seconds(3))
                    return $0.map { $0.capitalized }
                })
            }))
        slow.highlightTargetField = false; slow.muteSpeakersDuringDictation = false
        slow.keepAudioForSpeakerPass = false; slow.cleanUpTranscriptions = false
        slow.cleanUpDictation = true
        slow.beginRecoveryVerification(store: slowStore, startedAt: probe.now)
        slow.beginDictation()
        probe.now += 3
        slow.ingestRecoveryVerification(samples: Array(repeating: Float(5), count: 48_000), at: probe.now)
        await slow.waitForRecoveryVerification()
        slow.endDictation()
        await slow.waitForRecoveryVerification()
        precondition(probe.delivered.last == "Segment5", "Dictation inserted raw text instead of waiting for a three-second cleanup")
        slow.shutdown()
        print("PASS: dictation waits for a three-second cleanup and inserts the cleaned text.")
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
        service.newSessionAfterSilence = 1
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
        let first = service.activeSessionID
        await quiet(for: 30)
        precondition(service.activeSessionID == first, "A new session started before a minute of quiet")
        await quiet(for: 31)
        precondition(service.activeSessionID != first, "A minute of quiet did not start a new session")
        print("PASS: a minute of quiet after speech starts a new session on the next tick; half a minute does not.")

        await service.startMeeting("Standup")
        precondition(service.meetingTitle == "Standup", "The meeting did not start: \(service.notice)")
        await speak()
        let meeting = service.activeSessionID
        await quiet(for: 61)
        precondition(service.activeSessionID == meeting, "A named meeting started a new session after a minute of quiet")
        print("PASS: a named meeting keeps its session through the same quiet.")

        probe.now += 5
        service.tickRecoveryVerification()
        precondition(service.pauseRequested && service.notice.hasPrefix("Microphone stopped delivering audio"), "Five seconds without microphone audio did not pause")
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        print("PASS: five seconds without microphone audio pauses automatically.")
    }

    /// Every screen observes the whole service, so each published assignment tells the window to redraw. Listening should do that once a second for the CPU and memory readout, not on every audio drain or after a recognition that finds no speech.
    @MainActor static func checkIdleRedraws(directory: URL) async throws {
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("idle"))
        var recognitions = 0
        let service = SpeechService(dependencies: .init(infer: { _, _, _ in
            recognitions += 1
            return SpeechOutput(transcripts: [], text: "", processingSeconds: 0.05)
        }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        var changes = 0
        let counter = service.objectWillChange.sink { changes += 1 }
        defer { counter.cancel() }
        // Two seconds of digital silence, drained and ticked every 0.2 seconds like the timer. Every 0.8 seconds the silence closes a chunk, and recognition finds no speech in it.
        for _ in 1...10 {
            probe.now += 0.2
            service.ingestRecoveryVerification(samples: Array(repeating: 0, count: 3_200), rms: 0, at: probe.now)
            service.tickRecoveryVerification()
            await service.waitForRecoveryVerification()
        }
        precondition(recognitions == 2, "Two seconds of silence ran \(recognitions) recognitions, not two")
        precondition(changes == 2, "Two seconds of listening told the window to redraw \(changes) times, not twice")
        print("PASS: two seconds of listening to silence, with two recognitions that find no speech, tell the window to redraw exactly twice: once a second for the CPU and memory readout.")
    }

    @MainActor static func checkRealRecognition(_ file: URL) async throws {
        let source = try AudioConverter().resampleAudioFile(file)
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
        service.beginDictation()
        let started = ContinuousClock.now
        for lower in stride(from: 0, to: samples.count, by: 48_000) {
            let chunk = Array(samples[lower..<min(lower + 48_000, samples.count)])
            probe.now += AudioClock.seconds(samples: chunk.count)
            service.ingestRecoveryVerification(samples: chunk, at: probe.now)
            await service.waitForRecoveryVerification()
        }
        service.endDictation()
        await service.waitForRecoveryVerification()
        let text = probe.delivered.last ?? ""
        precondition(probe.delivered.count == 1 && !text.isEmpty, "Real recognition did not deliver the held fixture")
        let durations = service.diagnostics.report.jobs.map(\.audioSeconds)
        precondition(durations.allSatisfy { $0 <= 3.001 }, "Real recognition received a long blocking chunk")
        print("REAL ASR: \(AudioClock.seconds(samples: samples.count)) audio seconds, \(durations.count) chunks, \(started.duration(to: .now)) elapsed.")
        // The source must be a synthetic fixture; never pass private recorded audio
        // when retaining this log or posting it in a PR.
        print("REAL ASR TEXT: \(text)")
        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        service.shutdown()
    }
}
