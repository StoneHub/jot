import AppKit
import Foundation
import JotCore

/// Drives the real service through Resume with a microphone that refuses to start, using the dependency seams instead of Core Audio, model downloads, or permission dialogs.
enum CaptureFlowChecks {
    final class FakeMicrophone: MicrophoneSource, @unchecked Sendable {
        var failuresBeforeStart = 0
        var startCalls = 0
        var drains = 0
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
        func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
            drains += 1
            return ([], 0, Date(), 0)
        }
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

        // An open menu or a live window resize runs the main run loop in event-tracking mode, from an event the run loop delivers. AppKit makes that mode common; this tool has no NSApplication, so it does the same, and a one-shot timer stands in for the event.
        let tracking = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
        // A mode cannot be removed from the common modes, so event tracking stays common for the rest of this harness run, as it does in the app.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), tracking)
        microphone.drains = 0
        let drains = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            let openMenu = Timer(timeInterval: 0, repeats: false) { _ in
                CFRunLoopRunInMode(tracking, 1, false)
                done.resume(returning: microphone.drains)
            }
            RunLoop.main.add(openMenu, forMode: .default)
        }
        precondition(drains >= 2, "Audio drained \(drains) times in a second of menu tracking")
        print("PASS: audio keeps draining while a menu is open or the window is being resized.")

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

        // A meeting renamed over the socket keeps the new name, including through an automatic pause.
        await service.startMeeting("Standup")
        let rename: [String: Any] = ["method": "sessions.title", "params": ["sessionID": service.activeSessionID ?? "", "title": "Weekly sync"]]
        _ = await service.handle(try JSONSerialization.data(withJSONObject: rename))
        precondition(service.meetingTitle == "Weekly sync", "The running meeting kept the name \(service.meetingTitle ?? "nil") after a socket rename")
        service.pause(automatic: true)
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && service.meetingTitle == "Weekly sync", "The meeting continued as \(service.meetingTitle ?? "nil") after an automatic pause")
        service.pause()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        print("PASS: a failed microphone start retries, reports after the last try, explains a blocked shortcut press, and Resume restarts capture.")
        print("PASS: a meeting renamed over the socket keeps the new name through an automatic pause.")
    }
}
