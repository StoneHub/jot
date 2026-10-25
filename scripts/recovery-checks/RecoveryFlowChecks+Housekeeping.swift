import Combine
import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
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
        // Digital silence waits for the chunk limit, so the shortest one keeps chunks closing during the run.
        service.settings.set(JotSettings.chunkMaximumSeconds, 1.0)
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown(); try? service.settings.reset(JotSettings.chunkMaximumSeconds) }
        var changes = 0
        // TranscriptView observes the service, the library and the timeline; a publish from any of them redraws the whole window.
        let counter = service.objectWillChange.merge(with: service.library.objectWillChange, service.timeline.objectWillChange).sink { changes += 1 }
        defer { counter.cancel() }
        // Five seconds of digital silence, drained and ticked every 0.2 seconds like the timer. Every second the chunk limit closes a chunk, and recognition finds no speech in it. Each status second lands on a chunk close, the coincidence that used to redraw the window.
        for _ in 1...25 {
            probe.now += 0.2
            microphone.lastAudio = probe.now
            service.tickRecoveryVerification()
            await service.waitForRecoveryVerification()
        }
        precondition(recognitions == 5, "Five seconds of silence ran \(recognitions) recognitions, not five")
        precondition(changes == 0, "Resource-only ticks told the whole window to redraw \(changes) times")
        print("PASS: resource-only ticks and five recognitions that find no speech do not invalidate the whole window, even when the status second lands on a chunk close.")

        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        // The transition takes one fresh CPU interval before returning to minute ticks.
        try await Task.sleep(for: .milliseconds(1200))
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
        precondition(service.tickInterval == LowPowerListening.tickInterval(0.2), "Listening no longer drains audio five times a second (twice in Low Power Mode)")
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
}
