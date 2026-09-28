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
        var pendingSamples: [Float] = []
        var selectedUID: String?
        var bufferedSampleCount: Int { pendingSamples.count }
        func setInput(uid: String?) throws {
            precondition(!running, "The input was changed before its captured samples were drained")
            selectedUID = uid
        }
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
            let samples = pendingSamples
            pendingSamples = []
            return (samples, 0, Date(), samples.contains(where: { $0 != 0 }) ? 0.01 : 0)
        }
    }

    @MainActor static func run() async throws {
        let microphone = FakeMicrophone()
        var dependencies = SpeechServiceDependencies(
            infer: { _, job, _ in
                guard job.samples.contains(where: { $0 != 0 }) else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset,
                    endSeconds: job.offset + AudioClock.seconds(samples: job.samples.count), text: "saved before switch", mode: "ambient")
                return SpeechOutput(transcripts: [row], text: row.text, processingSeconds: 0)
            },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init)
        dependencies.makeMicrophone = { microphone }
        dependencies.availableInputs = { [.init(id: "built-in", name: "Built-in"), .init(id: "verification-hub", name: "Hub")] }
        dependencies.defaultInputUID = { "built-in" }
        dependencies.microphoneRetry = MicrophoneStartRetry(delays: [0.01, 0.01])
        dependencies.prepareModels = { _ in }
        dependencies.unloadModels = { _ in }
        dependencies.microphoneAuthorization = { .authorized }
        dependencies.requestMicrophoneAccess = { true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-input-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SpeechService(dependencies: dependencies)
        service.library.store = try TranscriptStore(directory: directory)
        service.capture.refreshInputDevices()
        service.automaticMicrophone = true
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

        let beforeSwitch = service.timeline.sessionID
        microphone.pendingSamples = [Float](repeating: 0.01, count: 8000)
        service.setInput(uid: "verification-hub")
        await service.waitForInputChange()
        precondition(service.capture.selectedInputUID == "verification-hub" && service.ambientEnabled && microphone.running,
                     "Choosing a microphone while listening did not switch and resume: \(service.notice), \(service.capture.selectedInputUID), \(service.mode)")
        let saved = try service.library.store!.session(id: beforeSwitch)
        precondition(saved.count == 1 && saved[0].endSeconds == 0.5, "Changing microphone lost the final half second")
        precondition(service.timeline.sessionID != beforeSwitch, "The new input reused the old recognition timeline")
        service.setInput(uid: "")
        await service.waitForInputChange()
        // Ten seconds of digital silence on the default input tries the hub. Three seconds with signal keeps it.
        microphone.pendingSamples = [Float](repeating: 0, count: 160_000)
        service.tickRecoveryVerification()
        await service.waitForInputChange()
        precondition(service.capture.selectedInputUID == "verification-hub" && service.capture.findingInput,
                     "Silent default input did not try the connected hub")
        microphone.pendingSamples = [Float](repeating: 0.01, count: 48_000)
        service.tickRecoveryVerification()
        await service.waitForRecoveryVerification()
        precondition(!service.capture.findingInput && service.capture.selectedInputUID == "verification-hub",
                     "Automatic search did not keep the input with sound")
        print("PASS: changing a listening microphone saves its tail and resumes; digital silence automatically finds the hub with sound.")

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
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        precondition(service.lifecycle.phase == .ready && service.modelsLoaded && service.isPaused, "Pause did not keep the models loaded")
        precondition(service.input.startBlocker() == nil, "A hold while paused was blocked: \(service.input.startBlocker() ?? "nil")")
        microphone.startCalls = 0; microphone.failuresBeforeStart = .max
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(!service.ambientEnabled && service.microphoneOff, "A microphone that never starts should leave the service ready with capture off")
        precondition(microphone.startCalls == 3, "Expected three tries, got \(microphone.startCalls)")
        precondition(service.notice.hasPrefix("The microphone did not start after 3 tries"), "Final notice: \(service.notice)")
        precondition(service.input.startBlocker() == nil, "With the models loaded, a press starts the microphone for the hold; it was blocked: \(service.input.startBlocker() ?? "nil")")

        // Resume with the models already loaded only restarts the microphone.
        microphone.failuresBeforeStart = 0
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && service.lifecycle.phase == .ready, "Resume did not restart the microphone")
        precondition(service.input.startBlocker() == nil, "Press still blocked after Resume")

        // A meeting renamed over the socket keeps the new name, including through an automatic pause.
        await service.startMeeting("Standup")
        let rename: [String: Any] = ["method": "sessions.title", "params": ["sessionID": service.timeline.activeSessionID ?? "", "title": "Weekly sync"]]
        _ = await service.handle(try JSONSerialization.data(withJSONObject: rename))
        precondition(service.meetingTitle == "Weekly sync", "The running meeting kept the name \(service.meetingTitle ?? "nil") after a socket rename")
        service.pause(automatic: true)
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && service.meetingTitle == "Weekly sync", "The meeting continued as \(service.meetingTitle ?? "nil") after an automatic pause")
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        print("PASS: a failed microphone start retries, reports after the last try, explains a blocked shortcut press, and Resume restarts capture.")
        print("PASS: a meeting renamed over the socket keeps the new name through an automatic pause.")

        // A hold while paused turns the microphone on for the hold only, in a session of its own, and off again on release.
        microphone.startCalls = 0
        let pausedSession = service.timeline.activeSessionID
        service.holdBegan()
        while !service.dictation.isActive { try await Task.sleep(for: .milliseconds(5)) }
        precondition(microphone.running && service.ambientEnabled && service.holdOnlyCapture && service.timeline.activeSessionID != pausedSession,
                     "The hold did not start the microphone in a session of its own")
        service.holdEnded(releasedAt: ProcessInfo.processInfo.systemUptime)
        await service.dictation.waitForRecovery()
        precondition(!microphone.running && !service.ambientEnabled && !service.holdOnlyCapture && service.isPaused && service.modelsLoaded,
                     "The microphone stayed on after the held dictation")
        precondition(!service.ambientRequested, "A hold while paused turned listening back on")
        print("PASS: a hold while paused runs the microphone for the hold only and leaves Jot paused with the models loaded.")

        // Paused, the hooks are refused and the models are still loaded; Unload Models is the only release, and Resume after it loads them again.
        let hook: [String: Any] = ["method": "context.hook", "params": ["role": "user", "source": "codex", "conversation": "c1", "text": "hello"]]
        let refusedData = await service.handle(try JSONSerialization.data(withJSONObject: hook))
        let refused = try JSONSerialization.jsonObject(with: refusedData) as? [String: Any]
        precondition(refused?["ok"] as? Bool == false && service.agentContext.count == 0, "A hook message was taken while paused")
        service.unloadModels()
        while service.lifecycle.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!service.modelsLoaded && !service.ambientEnabled && service.isPaused, "Unload Models left the models loaded")
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        precondition(service.ambientEnabled && service.modelsLoaded, "Resume after Unload Models did not reload the models and listen")
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        print("PASS: Pause keeps the models loaded and refuses hook context; Unload Models releases them and Resume reloads.")

        service.setInput(uid: "built-in")
        await service.waitForInputChange()
        precondition(!microphone.running && !service.ambientEnabled, "Changing a paused microphone started listening")
        service.prepare(confirmingDownload: true)
        await service.waitForPreparation()
        await service.startMeeting("Update check")
        let beforeUpdate = service.timeline.sessionID
        microphone.pendingSamples = [Float](repeating: 0.01, count: 8000)
        try await service.prepareForUpdate()
        let beforeUpdateRows = try service.library.store!.session(id: beforeUpdate)
        precondition(!microphone.running && service.canInstallUpdate && beforeUpdateRows.count == 1,
                     "Update did not save pending microphone audio before allowing replacement")
        precondition(!UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused) &&
                     UserDefaults.standard.string(forKey: JotDefaultsKey.updateMeetingTitle) == "Update check",
                     "Update did not preserve listening and meeting intent for relaunch")
        service.holdBegan()
        precondition(!service.dictation.isActive && !microphone.running && service.input.startBlocker() != nil,
                     "New dictation was allowed after update preparation")
        service.cancelUpdatePreparation()
        while !service.ambientEnabled { try await Task.sleep(for: .milliseconds(5)) }
        await service.waitForPreparation()
        precondition(microphone.running && service.meetingTitle == "Update check", "A failed update did not restore listening")
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(5)) }
        try await service.prepareForUpdate()
        precondition(UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused), "Updating a paused app would start capture at relaunch")
        service.cancelUpdatePreparation()
        precondition(!microphone.running, "Failed update started a previously paused microphone")
        print("PASS: Update saves the audio tail, preserves listening and meeting intent, blocks new intake, and restores listening on failure; paused updates stay paused.")
    }
}
