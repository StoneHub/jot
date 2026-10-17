import Combine
import Foundation
import JotCore
import JotEngine

/// `JotRecoveryChecks --listening-overhead` measures what the service itself does around recognition while it listens, with recognition stubbed to return at once: the once-a-second status work, the 0.2-second timer tick that drains the microphone, saving a row, and how often each of them tells every screen to redraw (`objectWillChange`). Nothing here starts a microphone or a window; the redraw cost itself is the screens', measured on the installed app. `JOT_OVERHEAD_SECONDS` sizes the wall-clock runs.
extension RecoveryFlowChecks {
    /// A microphone that owes the same packet on every drain: `seconds` of one sample value, at the RMS the tap would report for it. The caller keeps `lastAudio` on its clock, real or fake, so the stalled-input check sees audio arriving.
    final class ConstantMicrophone: MicrophoneSource, @unchecked Sendable {
        private let packet: [Float]
        private let rms: Float
        var lastAudio = Date()
        private(set) var running = false
        init(seconds: Double, value: Float) {
            packet = Array(repeating: value, count: AudioClock.samples(seconds: seconds))
            rms = abs(value)
        }
        var bufferedSampleCount: Int { 0 }
        func setInput(uid: String?) throws {}
        func setInputForNextStart(uid: String?) {}
        func shouldIgnoreConfigurationChange() -> Bool { false }
        func start() throws { running = true }
        func stop() { running = false }
        func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) { (packet, 0, lastAudio, rms) }
    }

    @MainActor static func measureListeningOverhead() async throws {
        func perCall(_ label: String, _ count: Int, _ body: () -> Void) {
            let began = kernelCPUSeconds()
            for _ in 0..<count { body() }
            let seconds = kernelCPUSeconds() - began
            print(String(format: "OVERHEAD CALL: %@: %.4f ms CPU per call over %d calls", label, seconds / Double(count) * 1000, count))
        }
        let sampler = ResourceSampler()
        perCall("ResourceSampler.sample (proc_pid_rusage)", 2000) { _ = sampler.sample() }
        perCall("DictationInput.accessibilityGranted (AXIsProcessTrusted)", 2000) { _ = DictationInput.accessibilityGranted }
        let live = SpeechServiceDependencies.live
        perCall("AVCaptureDevice.authorizationStatus(.audio)", 2000) { _ = live.microphoneAuthorization() }
        perCall("TranscriptCleanup.availability (Foundation Models)", 200) { _ = TranscriptCleanup.availability }

        let seconds = Double(ProcessInfo.processInfo.environment["JOT_OVERHEAD_SECONDS"] ?? "") ?? 40
        // Each run: the real service on the wall clock, its timer tick called every 0.2 seconds as the timer would, the fake microphone owing 0.2 seconds of audio per drain. Recognition is stubbed: no speech, or one row per block.
        struct Run { let name: String; let value: Float; let rows: Bool; let ticks: Bool }
        let runs = [
            Run(name: "digital silence, tick path (drain + once-a-second status work)", value: 0, rows: false, ticks: true),
            Run(name: "digital silence, drain only (no tick, no status work)", value: 0, rows: false, ticks: false),
            Run(name: "steady tone above the gate, one saved row per 3-second block, tick path", value: 0.01, rows: true, ticks: true),
        ]
        for run in runs {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-overhead-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try TranscriptStore(directory: directory)
            var jobs = 0, rowsSaved = 0
            var dependencies = SpeechServiceDependencies(infer: { _, job, _ in
                jobs += 1
                guard run.rows, !job.samples.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
                let duration = AudioClock.seconds(samples: job.samples.count)
                let text = "block \(jobs) of steady tone with eight words"
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset, endSeconds: job.offset + duration, text: text, speakerID: "speaker-1", mode: "ambient")
                let words = text.split(separator: " ").enumerated().map { index, word in
                    AttributedWord(text: String(word), start: Double(index) * duration / 8, end: Double(index + 1) * duration / 8, probabilities: [0.9, 0.05, 0.03, 0.02])
                }
                rowsSaved += 1
                return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0, wordsByTranscript: [row.id: words])
            }, deliver: { _, _ in .init(verified: true, path: "synthetic", outcome: "verified", targetApp: "synthetic-test", targetPID: 0, role: "AXTextField", subrole: nil) }, now: { Date() })
            let microphone = ConstantMicrophone(seconds: 0.2, value: run.value)
            dependencies.makeMicrophone = { microphone }
            let service = SpeechService(dependencies: dependencies)
            service.keepAudioForSpeakerPass = false; service.cleanUpTranscriptions = false; service.cleanUpDictation = false
            service.highlightTargetField = false; service.muteSpeakersDuringDictation = false; service.newSessionAfterSilence = 0
            service.beginRecoveryVerification(store: store)
            try microphone.start()
            var invalidations = 0
            let counter = service.objectWillChange.merge(with: service.library.objectWillChange, service.timeline.objectWillChange).sink { invalidations += 1 }
            var readouts = 0
            let meters = service.resourceReadout.$snapshot.dropFirst().sink { _ in readouts += 1 }
            let ticks = Int(seconds / 0.2)
            let began = ContinuousClock.now
            let cpuBegan = kernelCPUSeconds()
            for tick in 1...ticks {
                microphone.lastAudio = Date()
                if run.ticks { service.tickRecoveryVerification() }
                else { service.drainAudio(); service.transcriber.kick() }
                try await Task.sleep(until: began + .milliseconds(200 * tick), clock: .continuous)
            }
            await service.waitForRecoveryVerification()
            let cpu = kernelCPUSeconds() - cpuBegan
            let wall = Double(began.duration(to: .now) / .milliseconds(1)) / 1_000
            counter.cancel(); meters.cancel()
            print(String(format: "OVERHEAD RUN: %@: %.1f s wall, %.3f CPU s (%.2f CPU s per minute, %.2f%% of a core), %d ticks, %d recognition jobs, %d rows saved, %d meter readouts, %d whole-window invalidations",
                run.name, wall, cpu, cpu / wall * 60, cpu / wall * 100, ticks, jobs, rowsSaved, readouts, invalidations))
            service.shutdown()
        }
    }
}
