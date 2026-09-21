import AppKit
import Foundation
import JotCore

/// Drives the real service through Resume with a microphone that refuses to start, using the dependency seams instead of Core Audio, model downloads, or permission dialogs.
enum CaptureFlowChecks {
    final class FakeMicrophone: MicrophoneSource, @unchecked Sendable {
        var failuresBeforeStart = 0
        var startCalls = 0
        var running = false
        var bufferedSampleCount: Int { 0 }
        func setInput(uid: String?) throws {}
        func setInputForNextStart(uid: String?) {}
        func shouldIgnoreConfigurationChange() -> Bool { false }
        func start() throws {
            startCalls += 1
            if startCalls <= failuresBeforeStart { throw JotError.message("bad device") }
            running = true
        }
        func stop() { running = false }
        func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) { ([], 0, Date(), 0) }
    }

    @MainActor static func run() async throws {
        let microphone = FakeMicrophone()
        var dependencies = SpeechServiceDependencies(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init)
        dependencies.makeMicrophone = { microphone }
        dependencies.microphoneRetry = MicrophoneStartRetry(delays: [0.01, 0.01])
        dependencies.prepareModels = { _ in }
        dependencies.unloadModels = { _ in }
        dependencies.microphoneAuthorization = { .authorized }
        dependencies.requestMicrophoneAccess = { true }
        let service = SpeechService(dependencies: dependencies)
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        defer { service.shutdown() }

        // Two refusals, then the device is back: listening starts without anyone pressing Resume.
        microphone.failuresBeforeStart = 2
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && microphone.startCalls == 3, "Capture did not recover after two failed starts")
        precondition(service.notice.isEmpty, "A recovered start left a notice behind: \(service.notice)")
        precondition(service.input.startBlocker() == nil, "A shortcut press is blocked while listening")

        // The device never comes back: the retries stop, the notice says so, and a shortcut press explains itself.
        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        microphone.startCalls = 0; microphone.failuresBeforeStart = .max
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(!service.ambientEnabled && service.microphoneOff, "A microphone that never starts should leave the service ready with capture off")
        precondition(microphone.startCalls == 3, "Expected three tries, got \(microphone.startCalls)")
        precondition(service.notice.hasPrefix("The microphone did not start after 3 tries"), "Final notice: \(service.notice)")
        precondition(service.input.startBlocker() == "The microphone is off. Choose Resume to start it.", "Blocked press reason: \(service.input.startBlocker() ?? "nil")")

        // Resume with the models already loaded only restarts the microphone.
        microphone.failuresBeforeStart = 0
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && service.lifecycle.phase == .ready, "Resume did not restart the microphone")
        precondition(service.input.startBlocker() == nil, "Press still blocked after Resume")
        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        print("PASS: a failed microphone start retries, reports after the last try, explains a blocked shortcut press, and Resume restarts capture.")
    }
}
