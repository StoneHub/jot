import AppKit
import Foundation
import JotCore
import FluidAudio
import SQLite3

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
        service.showLive(service.activeSessionID)

        service.beginDictation()
        for index in 1...25 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
            let count = try store.session(id: service.activeSessionID!).count
            precondition(count == index, "Speech was not persisted while the hold was still active")
            precondition(service.live.paragraphs.last?.text.hasSuffix("segment\(index)") == true, "Live did not add the row when it was saved")
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
        let fullRead = service.sessionParagraphs(service.activeSessionID!).map(\.text)
        precondition(service.live.paragraphs.map(\.text) == fullRead, "Live differs from a full read of the session")
        precondition(service.live.paragraphs.contains { $0.mode == "dictation" }, "Live did not show the saved dictation")
        print("PASS: Live adds each saved row and the held dictation as they are saved, matching a full read.")

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
        try await checkLiveFollowsEdits(directory: directory)
        try await checkInterruptedHold(directory: directory)
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
        try await checkSpeakerPassKeepsCleanup(directory: directory)
        try await checkRelabelsTakeTurns(directory: directory)
        try await checkSpeakerPassKeepsMainFree(directory: directory)
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
        cleaned.showLive(cleaned.activeSessionID)
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
        precondition(cleaned.live.paragraphs.map(\.text) == ["segment1 segment2"] && cleaned.live.cleanupRevision == 0,
            "Live did not show raw rows as they were saved")
        await cleaned.waitForRecoveryVerification()
        let readable = try cleanedStore.session(id: cleaned.activeSessionID!)
        precondition(readable.map(\.text) == ["Segment1", "Segment2"], "Phrase cleanup dropped work while the model was busy")
        precondition(cleaned.recoveryDiagnostics["cleanupApplied"] as? Int == 2, "Cleanup outcome was not reported")
        precondition(cleaned.live.paragraphs.map(\.text) == ["Segment1 Segment2"] && cleaned.live.cleanupRevision == 2,
            "Live did not put cleaned text in place of the raw text")
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
        service.peopleStore = try PeopleStore(directory: folder)
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let id = service.activeSessionID!
        service.showLive(id)
        func speak(_ index: Int) async {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        func shown() -> [String] {
            service.live.paragraphs.map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }
        func fullRead() -> [String] {
            service.sessionParagraphs(id).map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }

        for index in 1...4 {
            await speak(index)
        }
        precondition(shown().last == "Speaker 2: segment4" && shown() == fullRead(), "Live lost a saved row when the next row of its block could not be saved")
        let revision = service.live.revision
        service.showLive(id)
        precondition(service.live.revision == revision, "Live read its session again when it was shown a second time")
        service.beginDictation()
        await speak(5)
        service.endDictation()
        await service.waitForRecoveryVerification()
        precondition(service.live.paragraphs.contains { $0.mode == "dictation" } && shown() == fullRead(), "Live did not show the session as saved")

        service.labelSpeaker(session: id, speaker: "speaker-1", name: "Ada")
        precondition(shown().contains("Ada: segment1") && shown() == fullRead(), "Live kept the old name after a speaker was named")
        service.notice = ""
        // A voice of zeros cannot be remembered. The name is saved before that fails.
        service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace", voice: [0, 0])
        precondition(!service.notice.isEmpty, "Remembering a voice of zeros did not fail")
        precondition(shown().contains("Grace: segment3") && shown() == fullRead(), "Live kept the old name when remembering the voice failed")
        let request = try JSONSerialization.data(withJSONObject: ["method": "speakers.label", "params": ["sessionID": id, "speakerID": "speaker-1", "name": "Ada King"]])
        let reply = try JSONSerialization.jsonObject(with: await service.handle(request)) as? [String: Any]
        precondition(reply?["ok"] as? Bool == true, "speakers.label failed over the socket")
        precondition(shown().contains("Ada King: segment1") && shown() == fullRead(), "Live kept the old name after speakers.label")

        service.tuning.paragraphPause = 2.5
        precondition(shown().contains("Ada King: segment1 segment2") && shown() == fullRead(), "Live kept the old paragraphs after a new paragraph pause")
        let paused = service.live.revision
        service.tuning.speakerConfidence = 0.8
        precondition(service.live.revision == paused, "Live read its session again after a setting it does not group by")
        try service.deleteHistoryCard(service.history.first!)
        precondition(!service.live.paragraphs.contains { $0.mode == "dictation" } && shown() == fullRead(), "Live still showed a deleted row")

        // Hiding the names table makes the session read fail. Live still moves to the session, so a row saved next shows, and the next reload reads the whole session.
        service.showLive(nil)
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.showLive(id)
        precondition(!service.notice.isEmpty && service.live.paragraphs.isEmpty, "Reading the session without its names table did not fail")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        await speak(6)
        precondition(service.live.paragraphs.map(\.text) == ["segment6"], "Live dropped a row saved after a failed read")
        service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace Hopper")
        precondition(shown().contains("Ada King: segment1 segment2") && shown() == fullRead(), "Live did not read the session again after a failed read")

        // A reload of the shown session that fails keeps what Live shows, and the next show reads the session again.
        let kept = shown()
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.tuning.paragraphPause = 1.5
        precondition(!service.notice.isEmpty && shown() == kept, "Live dropped its rows when a reload of the shown session failed")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        service.showLive(id)
        precondition(shown().contains("Ada King: segment1") && shown() == fullRead(), "Live did not read the session again after a failed reload")
        print("PASS: Live keeps a row saved before a failed one, and reads its session again after a speaker name, a failed voice, speakers.label, a new paragraph pause, and a delete, but not after another setting or a second show.")
        print("PASS: after a failed switch Live shows the rows saved next; after a failed reload it keeps its rows; either way the next read retries.")
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

        first.beginDictation()
        probe.now += 3
        first.ingestRecoveryVerification(samples: Array(repeating: 1, count: 48_000), at: probe.now)
        await first.waitForRecoveryVerification()
        first.endDictation()
        await first.waitForRecoveryVerification()
        let finished = try store.latestRecoverableDictationAttempt()
        precondition(finished?.text == "email Dot", "The finished hold did not save dictation text")

        first.beginDictation()
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
        try second.dictation.finalizeInterruptedAttempts()
        probe.deliveryFails = false
        second.recoverRecentDictation()
        await second.waitForRecoveryVerification()
        second.recoverRecentDictation()
        await second.waitForRecoveryVerification()
        precondition(probe.delivered.first == "(Dot)", "Recovery inserted an interrupted hold's words without converting them with the saved vocabulary: \(probe.delivered)")
        precondition(probe.delivered.last == "email Dot", "Recovery converted a finished hold's dictation text a second time: \(probe.delivered)")
        second.shutdown()
        print("PASS: a hold interrupted by quit is converted once at the next launch and recovered as dictation text; a finished hold's saved text is inserted unchanged.")
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

    /// Resource samples must refresh their readouts without invalidating every screen that observes the service.
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
        precondition(changes == 0, "Resource-only ticks told the whole window to redraw \(changes) times")
        print("PASS: resource-only ticks and two recognitions that find no speech do not invalidate the whole window.")

        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        changes = 0
        var readouts = 0
        let meters = service.resourceReadout.$snapshot.dropFirst().sink { _ in readouts += 1 }
        defer { meters.cancel() }
        for _ in 1...6 {
            probe.now += 5
            service.tickRecoveryVerification()
        }
        precondition(readouts == 6, "Paused CPU and memory meters stopped refreshing")
        precondition(changes == 0, "Paused resource ticks told the whole window to redraw \(changes) times")
        precondition(service.resources.valid, "The diagnostic snapshot no longer sees the current resource readout")
        print("PASS: six paused ticks refresh the resource meters without invalidating the whole window.")
    }

    /// Holds phrase cleanup until opened, and says when a phrase is waiting at it.
    final class CleanupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var held = false
        var holding: Bool { lock.withLock { held } }
        func close() { lock.withLock { closed = true } }
        func open() { lock.withLock { closed = false } }
        func pass() async throws {
            guard lock.withLock({ closed }) else { return }
            lock.withLock { held = true }
            defer { lock.withLock { held = false } }
            while lock.withLock({ closed }) { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    /// A finished session keeps its cleaned text through the speaker pass and takes the pass's speakers; Regroup from the stored pass then changes nothing. Regroup pressed while a session's last phrase is still being cleaned keeps the cleaned text too. Regroup pressed before the pass has stored its segments ends with the pass's speakers and names, even when Regroup writes after the pass.
    @MainActor static func checkSpeakerPassKeepsCleanup(directory: URL) async throws {
        let folder = directory.appendingPathComponent("speaker-pass")
        let store = try TranscriptStore(directory: folder)
        let probe = Probe()
        let gate = CleanupGate()
        // One row per three-second block, with word times relative to the block as the recognizer reports them.
        let blocks: [[(word: String, start: Double, end: Double)]] = [
            [("so", 0, 0.4), ("we", 0.5, 0.9), ("should", 1.0, 1.4), ("ship", 2.0, 2.4), ("it", 2.5, 2.9)],
            [("on", 0.1, 0.4), ("friday", 0.5, 1.0), ("then", 1.1, 1.4), ("ok", 1.6, 2.0)]]
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                guard let index = job.samples.first.map(Int.init), index > 0 else {
                    return SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
                }
                let words = blocks[index - 1].map { AttributedWord(text: $0.word, start: $0.start, end: $0.end, probabilities: []) }
                let text = words.map(\.text).joined(separator: " ")
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + words[0].start, endSeconds: job.offset + words[words.count - 1].end, text: text, mode: "ambient")
                return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0, wordsByTranscript: [row.id: words])
            },
            deliver: { _, text in try probe.deliver(text) },
            now: { probe.now },
            cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { texts in
                    try await Task.sleep(for: .seconds(1))
                    try await gate.pass()
                    return texts.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                })
            }))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = true
        service.speakerStore = try SpeakerPassStore(directory: folder)
        service.peopleStore = try PeopleStore(directory: folder)
        // A remembered voice that matches the pass's first speaker.
        _ = try service.peopleStore?.add(name: "Ada", embedding: [1])
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        /// Speaks both blocks into the running session, then ends it the way quiet does: its last block goes out as a final job, which hands the whole phrase to cleanup.
        func speakAndEndSession() -> String {
            let id = service.activeSessionID!
            for index in 1...2 {
                probe.now += 3
                service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            }
            service.timeline.rotateSession()
            service.kickWorker()
            return id
        }
        let id = speakAndEndSession()
        service.showLive(id)
        // The first voice gives way to the second inside the first row, between "should" and "ship". Cleanup is still running when the pass arrives.
        let pass = SpeakerPassResult(segments: [("S1", 0, 1.7), ("S2", 1.7, 6)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 6, processingSeconds: 0.1)
        await service.speakers.apply(pass, session: id, truncated: false)
        // Live reloads after the pass names the voice, not only after the relabel.
        let named = service.live.paragraphs.filter { $0.speakerID == "speaker-1" }.map(\.speakerLabel)
        precondition(!named.isEmpty && named.allSatisfy { $0 == "Ada" }, "Live did not show the name the pass recognized: \(named), \(service.notice)")
        await service.waitForRecoveryVerification()
        let expected = ["So we should", "ship it on friday then ok."]
        let speakers = ["speaker-1", "speaker-2"]
        let paragraphs = service.sessionParagraphs(id)
        precondition(paragraphs.map(\.text) == expected, "The speaker pass lost cleaned text: \(paragraphs.map(\.text))")
        precondition(paragraphs.map(\.speakerID) == speakers, "The speaker pass labels were not applied: \(paragraphs.map(\.speakerID))")
        let events = try store.events(sessionID: id)
        precondition(events.contains { $0.kind == "speaker_pass" }, "The speaker pass recorded no event: \(service.notice)")
        let rows = try store.session(id: id).map(\.id)
        try await service.regroupSession(id)
        let regrouped = service.sessionParagraphs(id)
        precondition(regrouped.map(\.text) == expected && regrouped.map(\.speakerID) == speakers, "Regroup from the stored pass changed the session: \(regrouped.map(\.text))")
        let regroupedRows = try store.session(id: id).map(\.id)
        precondition(regroupedRows == rows, "Regroup from the stored pass replaced rows it only needed to keep")
        print("PASS: the speaker pass keeps a finished session's cleaned text, splits a row where the speaker changes, shows the voice it recognized in Live, and Regroup from the pass changes nothing.")

        // A second session ends the same way and has the same pass stored. Regroup is pressed while its phrase is still being cleaned.
        let second = speakAndEndSession()
        try service.speakerStore?.replace(sessionID: second, result: SpeakerPassRelabel.renumbered(pass))
        while !service.cleanup.isCleaning(session: second) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await service.regroupSession(second)
        await service.waitForRecoveryVerification()
        let duringCleanup = service.sessionParagraphs(second)
        precondition(duringCleanup.map(\.text) == expected, "Regroup during cleanup lost cleaned text: \(duringCleanup.map(\.text))")
        precondition(duringCleanup.map(\.speakerID) == speakers, "Regroup during cleanup did not apply the pass: \(duringCleanup.map(\.speakerID))")
        print("PASS: Regroup pressed while a session's last phrase is being cleaned waits for it and keeps the cleaned text.")

        // A third session ends the same way with no pass stored yet. Regroup is pressed while its phrase is held in cleanup, so it waits for the session to settle. The phrase is let go, and once the session settles the pass stores its segments, relabels and names the voice while Regroup still waits for its next look. Regroup then writes last.
        gate.close()
        let third = speakAndEndSession()
        while !gate.holding {
            try await Task.sleep(for: .milliseconds(1))
        }
        let storedBeforePress = try service.speakerStore?.segments(sessionID: third) ?? []
        precondition(storedBeforePress.isEmpty, "The pass's segments were stored before Regroup was pressed")
        let early = Task { try await service.regroupSession(third) }
        while !service.library.isRelabeling {
            try await Task.sleep(for: .milliseconds(1))
        }
        gate.open()
        while !service.sessionIsSettled(third) {
            try await Task.sleep(for: .milliseconds(1))
        }
        await service.speakers.apply(pass, session: third, truncated: false)
        precondition(service.library.isRelabeling, "Regroup finished before the pass relabeled, so it did not write last: \(service.notice)")
        try await early.value
        let afterEarly = service.sessionParagraphs(third)
        precondition(afterEarly.map(\.speakerID) == speakers, "Regroup pressed before the pass stored its segments replaced the pass's speakers: \(afterEarly.map(\.speakerID)), \(afterEarly.map(\.text))")
        precondition(afterEarly.map(\.text) == expected, "Regroup pressed before the pass lost cleaned text: \(afterEarly.map(\.text))")
        let earlyNames = afterEarly.map(\.speakerLabel)
        precondition(earlyNames == ["Ada", nil], "Regroup pressed before the pass stored its segments moved the name the pass recognized: \(earlyNames)")
        precondition(service.notice == "Session regrouped from the speaker pass.", "Regroup pressed before the pass did not regroup from it: \(service.notice)")
        print("PASS: Regroup pressed before the speaker pass stores its segments reads them after it waits, so the session keeps the pass's speakers and names.")
    }

    /// What relabel speaker closures did, recorded from whichever thread runs them.
    final class RelabelLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var entries: [String] { lock.withLock { recorded } }
        func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    }

    /// Relabels of one session take turns and hold off Install Update. A Regroup whose session is deleted while it waits returns quietly, a pass whose session is deleted while it waits leaves nothing behind, a pass whose relabel fails partway and a Regroup both reload Live, Regroup of a session without words says so, and the name sheet offers a pass voice only once the pass has relabeled the rows.
    @MainActor static func checkRelabelsTakeTurns(directory: URL) async throws {
        let folder = directory.appendingPathComponent("relabel-turns")
        let store = try TranscriptStore(directory: folder)
        let service = SpeechService(dependencies: .init(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        let passStore = try SpeakerPassStore(directory: folder)
        service.speakerStore = passStore
        service.beginRecoveryVerification(store: store)
        defer { service.shutdown() }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        /// A finished one-row session of two words, stored directly.
        func seed(_ session: String) throws {
            let row = Transcript(sessionID: session, startedAt: started, startSeconds: 0, endSeconds: 1, text: "one two", mode: "ambient")
            try store.append(row)
            try store.appendWords([
                StoredWord(transcriptID: row.id, position: 0, word: "one", startSeconds: 0, endSeconds: 0.4, probabilities: []),
                StoredWord(transcriptID: row.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.9, probabilities: [])])
        }
        /// Starts a relabel of the session whose speakers wait for the gate, and returns once it holds the session's turn.
        func hold(_ session: String, gate: DispatchSemaphore, log: RelabelLog) async throws -> Task<Bool, Error> {
            let relabel = Task {
                try await service.library.relabel(session) { words in
                    log.append("held began")
                    gate.wait()
                    log.append("held ended")
                    return words.map { _ in "speaker-1" }
                }
            }
            while !log.entries.contains("held began") {
                try await Task.sleep(for: .milliseconds(5))
            }
            return relabel
        }

        try seed("turns")
        precondition(service.canInstallUpdate, "Install Update was held off before any relabel")
        let gate = DispatchSemaphore(value: 0)
        let log = RelabelLog()
        let held = try await hold("turns", gate: gate, log: log)
        let next = Task {
            try await service.library.relabel("turns") { words in
                log.append("next")
                return words.map { _ in "speaker-2" }
            }
        }
        // Long enough for the next relabel to reach its speakers if nothing made it wait.
        try await Task.sleep(for: .milliseconds(300))
        precondition(!log.entries.contains("next"), "A second relabel of the session ran while the first held its turn: \(log.entries)")
        precondition(!service.canInstallUpdate, "Install Update was offered while a relabel was writing")
        gate.signal()
        _ = try await held.value
        _ = try await next.value
        precondition(log.entries == ["held began", "held ended", "next"], "The second relabel did not wait for the first: \(log.entries)")
        let labels = try store.session(id: "turns").map(\.speakerID)
        precondition(labels == ["speaker-2"], "The later relabel's speakers did not stay: \(labels)")
        precondition(service.canInstallUpdate, "Install Update stayed held off after the relabels finished")
        print("PASS: a second relabel of a session waits until the first has finished, the later one's speakers stay, and Install Update waits for both.")

        // Regroup waits behind the held relabel; the session is deleted before its turn comes.
        try seed("regroup-deleted")
        let regroupGate = DispatchSemaphore(value: 0)
        let regroupLog = RelabelLog()
        let regroupBlocker = try await hold("regroup-deleted", gate: regroupGate, log: regroupLog)
        let regroup = Task { try await service.regroupSession("regroup-deleted") }
        try await Task.sleep(for: .milliseconds(50))
        try service.deleteSession("regroup-deleted")
        regroupGate.signal()
        _ = try await regroupBlocker.value
        do {
            try await regroup.value
        } catch {
            preconditionFailure("Regroup of a session deleted while it waited reported: \(error.localizedDescription)")
        }
        precondition(service.notice == "Session deleted.", "Regroup of a deleted session changed the notice to: \(service.notice)")
        print("PASS: Regroup of a session deleted while it waited returns quietly.")

        // The pass stores its segments off the main thread, so they can land after the session is deleted. Here they land again while the pass waits for its turn, and the pass must remove them.
        try seed("pass-deleted")
        let passGate = DispatchSemaphore(value: 0)
        let passLog = RelabelLog()
        let passBlocker = try await hold("pass-deleted", gate: passGate, log: passLog)
        let result = SpeakerPassResult(segments: [("S1", 0, 0.45), ("S2", 0.45, 1)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 1, processingSeconds: 0.1)
        let pass = Task { await service.speakers.apply(result, session: "pass-deleted", truncated: false) }
        while try passStore.segments(sessionID: "pass-deleted").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try service.deleteSession("pass-deleted")
        try passStore.replace(sessionID: "pass-deleted", result: SpeakerPassRelabel.renumbered(result))
        passGate.signal()
        _ = try await passBlocker.value
        await pass.value
        let leftSegments = try passStore.segments(sessionID: "pass-deleted")
        precondition(leftSegments.isEmpty, "A pass for a deleted session left \(leftSegments.count) segments behind")
        let leftEvents = try store.events(sessionID: "pass-deleted")
        precondition(leftEvents.isEmpty, "A pass for a deleted session recorded events: \(leftEvents.map(\.kind))")
        print("PASS: a speaker pass whose session is deleted while it waits removes the segments it stored and records nothing.")

        // A pass whose relabel fails partway still reloads Live: the row it already relabeled stays relabeled. The second row's words were stored out of order across two batches, so its first piece fails the store's word check.
        let greeting = Transcript(sessionID: "fails", startedAt: started, startSeconds: 0, endSeconds: 0.3, text: "hi", speakerID: "speaker-4", mode: "ambient")
        let reply = Transcript(sessionID: "fails", startedAt: started, startSeconds: 0.4, endSeconds: 2.2, text: "one two three", speakerID: "speaker-4", mode: "ambient")
        try store.append(greeting)
        try store.append(reply)
        try store.appendWords([
            StoredWord(transcriptID: greeting.id, position: 0, word: "hi", startSeconds: 0, endSeconds: 0.2, probabilities: []),
            StoredWord(transcriptID: reply.id, position: 0, word: "one", startSeconds: 1.0, endSeconds: 1.2, probabilities: [])])
        try store.appendWords([
            StoredWord(transcriptID: reply.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.7, probabilities: []),
            StoredWord(transcriptID: reply.id, position: 2, word: "three", startSeconds: 2.0, endSeconds: 2.2, probabilities: [])])
        service.showLive("fails")
        let failing = SpeakerPassResult(segments: [("S1", 0, 1.5), ("S2", 1.5, 3)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 3, processingSeconds: 0.1)
        await service.speakers.apply(failing, session: "fails", truncated: false)
        precondition(service.notice.hasPrefix("Speaker pass failed"), "The relabel did not fail partway: \(service.notice)")
        let shown = service.live.paragraphs.map(\.speakerID)
        precondition(shown == ["speaker-1", "speaker-4"], "Live kept showing rows the failed relabel had already changed: \(shown)")
        print("PASS: a speaker pass whose relabel fails partway still reloads Live with the rows it changed.")

        // Regroup reloads Live too. Live's probabilities point every word at the first speaker, so Regroup relabels the row the capture labeled speaker-4.
        let regrouped = Transcript(sessionID: "regroup-reloads", startedAt: started, startSeconds: 0, endSeconds: 1, text: "one two", speakerID: "speaker-4", mode: "ambient")
        try store.append(regrouped)
        try store.appendWords([
            StoredWord(transcriptID: regrouped.id, position: 0, word: "one", startSeconds: 0, endSeconds: 0.4, probabilities: [0.9, 0, 0, 0]),
            StoredWord(transcriptID: regrouped.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.9, probabilities: [0.9, 0, 0, 0])])
        service.showLive("regroup-reloads")
        try await service.regroupSession("regroup-reloads")
        let regroupedLive = service.live.paragraphs.map(\.speakerID)
        precondition(regroupedLive == ["speaker-1"], "Live kept showing the speakers from before Regroup: \(regroupedLive)")
        print("PASS: Regroup reloads Live with the speakers it wrote.")

        // A session saved before words were kept cannot be regrouped, and Regroup says so.
        try store.append(Transcript(sessionID: "no-words", startedAt: started, startSeconds: 0, endSeconds: 1, text: "recorded before words were kept", mode: "ambient"))
        do {
            try await service.regroupSession("no-words")
            preconditionFailure("Regroup of a session without words reported nothing: \(service.notice)")
        } catch {
            let message = error.localizedDescription
            precondition(message == "This session was recorded before Jot kept word timings; it cannot be regrouped.", "Regroup of a session without words reported: \(message)")
        }
        print("PASS: Regroup of a session saved before words were kept says it cannot be regrouped.")

        // The pass stores its voices before it relabels the rows. While it waits its turn, a row still carries its live speaker id, which can name another voice in the pass, so the name sheet offers no voice to remember.
        try seed("voices")
        let voicesGate = DispatchSemaphore(value: 0)
        let voicesLog = RelabelLog()
        let voicesBlocker = try await hold("voices", gate: voicesGate, log: voicesLog)
        let voices = SpeakerPassResult(segments: [("S1", 0, 1)], speakers: ["S1": [1, 0]], durationSeconds: 1, processingSeconds: 0.1)
        let voicesPass = Task { await service.speakers.apply(voices, session: "voices", truncated: false) }
        while try passStore.speakers(sessionID: "voices").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = service.passEmbedding(session: "voices", speaker: "speaker-1")
        precondition(waiting == nil, "The name sheet offered a pass voice before the pass relabeled the rows: \(String(describing: waiting))")
        voicesGate.signal()
        _ = try await voicesBlocker.value
        await voicesPass.value
        let relabeled = service.passEmbedding(session: "voices", speaker: "speaker-1")
        precondition(relabeled != nil, "The name sheet offered no pass voice once the pass relabeled the rows: \(service.notice)")
        print("PASS: the name sheet offers a pass voice only once the pass has relabeled the session's rows.")
    }

    /// A speaker pass and a Regroup over a long session run while listening continues. The longest main-actor gap stays within 50 ms of the same run's gap with no relabel, and a microphone that holds one second never overflows into an audio gap.
    @MainActor static func checkSpeakerPassKeepsMainFree(directory: URL) async throws {
        let folder = directory.appendingPathComponent("long-session")
        let store = try TranscriptStore(directory: folder)
        // The real queue holds eight seconds; one second here makes a stall of a second or more lose audio.
        let microphone = ClockedMicrophone(holdingSeconds: 1)
        var dependencies = SpeechServiceDependencies(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init)
        dependencies.makeMicrophone = { microphone }
        let service = SpeechService(dependencies: dependencies)
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.speakerStore = try SpeakerPassStore(directory: folder)
        service.beginRecoveryVerification(store: store)
        defer { service.shutdown() }

        // 3,000 cleaned rows of ten words, each row three seconds like a live block.
        let session = "seeded"
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        let text = vocabulary.joined(separator: " ")
        var rows: [Transcript] = []
        var words: [StoredWord] = []
        for index in 0..<3_000 {
            let start = Double(index) * 3
            let row = Transcript(sessionID: session, startedAt: started, startSeconds: start, endSeconds: start + 2.95, text: text, mode: "ambient")
            rows.append(row)
            for (position, word) in vocabulary.enumerated() {
                let wordStart = start + Double(position) * 0.3
                words.append(StoredWord(transcriptID: row.id, position: position, word: word, startSeconds: wordStart, endSeconds: wordStart + 0.25, probabilities: []))
            }
        }
        for row in rows {
            try store.append(row)
        }
        for start in stride(from: 0, to: words.count, by: 15_000) {
            try store.appendWords(Array(words[start..<min(start + 15_000, words.count)]))
        }
        let readable = Array(repeating: "Alpha bravo charlie delta echo foxtrot golf hotel india juliet.", count: rows.count)
        let seeded = try store.setReadablePhrase(readable, for: rows)
        precondition(seeded, "The long session was not seeded")
        // 1,500 six-second turns rotating three voices. Each turn starts halfway through a row, so the pass splits every other row. Regroup from the same segments then relabels all 4,500 rows in place.
        let segments = (0..<1_500).map { turn in (speaker: "S\(turn % 3 + 1)", start: Double(turn) * 6 + 1.5, end: Double(turn) * 6 + 7.5) }
        let pass = SpeakerPassResult(segments: segments, speakers: ["S1": [1], "S2": [2], "S3": [3]], durationSeconds: 9_000, processingSeconds: 1)

        // Listening goes on. Every 5 ms the ticker drains the microphone and does what a recognized block does: it saves a row and its word, adds the row to Live, and refreshes the recent rows and the Sessions list. It returns the longest gap between wakes beyond the 5 ms it sleeps.
        let listening = service.activeSessionID!
        func listen() -> Task<Duration, Never> {
            // The clock starts before the ticker's first run, so a stall that keeps it from starting is counted too.
            let tickerStarted = ContinuousClock.now
            return Task { @MainActor () -> Duration in
                var longest = Duration.zero
                var last = tickerStarted
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = ContinuousClock.now
                    longest = max(longest, last.duration(to: now) - .milliseconds(5))
                    last = now
                    service.drainAudio()
                    service.kickWorker()
                    ticks += 1
                    let start = Double(ticks) * 0.01
                    let row = Transcript(sessionID: listening, startedAt: started, startSeconds: start, endSeconds: start + 0.005, text: "tick", mode: "ambient")
                    try? store.append(row)
                    service.appendLive([row])
                    try? store.appendWords([StoredWord(transcriptID: row.id, position: 0, word: "tick", startSeconds: start, endSeconds: start + 0.005, probabilities: [])])
                    service.refreshRecent()
                    service.refreshSessions()
                }
                return longest
            }
        }
        try microphone.start()
        let quiet = listen()
        try await Task.sleep(for: .seconds(1))
        quiet.cancel()
        let baseline = await quiet.value
        let ticker = listen()
        try await Task.sleep(for: .milliseconds(20))
        let began = ContinuousClock.now
        await service.speakers.apply(pass, session: session, truncated: false)
        let passTime = began.duration(to: .now)
        try await service.regroupSession(session)
        let total = began.duration(to: .now)
        ticker.cancel()
        let gap = await ticker.value
        let events = try store.events(limit: 200)
        let rowCount = try store.session(id: session).count
        let cleanedCount = try store.readableTexts(sessionID: session).count
        precondition(events.contains { $0.kind == "speaker_pass" }, "The speaker pass did not finish: \(service.notice)")
        precondition(rowCount == 4_500, "Every other row should have split in two, not \(rowCount) rows")
        precondition(cleanedCount == 4_500, "A relabeled row lost its cleaned text: \(cleanedCount) cleaned rows")
        let allowed = max(.milliseconds(50), baseline + .milliseconds(50))
        func milliseconds(_ duration: Duration) -> String { String(format: "%.1f ms", Double(duration / .microseconds(1)) / 1_000) }
        func seconds(_ duration: Duration) -> String { String(format: "%.2f s", Double(duration / .milliseconds(1)) / 1_000) }
        let timing = "longest main-actor gap \(milliseconds(gap)) against \(milliseconds(baseline)) with no relabel, pass \(seconds(passTime)), pass and Regroup \(seconds(total)), \(service.droppedSeconds) s of audio dropped"
        print("Speaker pass over 3,000 rows: \(timing).")
        precondition(gap < allowed, "The main actor stalled during the pass: \(timing)")
        precondition(service.droppedSeconds == 0, "Listening dropped \(service.droppedSeconds) s of audio during the pass")
        precondition(!events.contains { $0.kind == "audio_gap" }, "An audio gap was recorded during the pass")
        print("PASS: a speaker pass and Regroup over 3,000 rows keep the main actor's longest gap within 50 ms of listening alone, and a microphone holding one second drops no audio.")
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
