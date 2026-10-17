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
}
