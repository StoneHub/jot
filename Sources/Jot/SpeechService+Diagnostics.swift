import Foundation
import JotCore
import JotEngine

/// What `jot diagnostics`, the recovery harness and Models read: performance samples, capture events and model update checks.
/// Counts, timings and state only; transcript and field contents never enter them.
extension SpeechService {
    /// Records CPU and memory for `jot diagnostics`. The window's readout comes from the tick, with a sampler of its own.
    func samplePerformance() {
        let sample = sampler.sample()
        guard sample.valid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: sample.physicalFootprintMiB,
            residentMiB: sample.residentMiB, cpuPercent: sample.processCPUPercent,
            droppedAudioSeconds: droppedSeconds, bufferedAudioSeconds: AudioClock.seconds(samples: capture.bufferedSampleCount + timeline.bufferedSampleCount) + transcriber.inFlightAudioSeconds,
            queuedAudioSeconds: transcriber.queuedAudioSeconds, loadedHistoryRows: library.history.count,
            modelsReady: modelState == .ready, ambientEnabled: ambientEnabled, dictationActive: dictation.isActive,
            inferenceRunning: transcriber.processing != nil))
    }

    func markPerformance(_ kind: PerformanceEventKind) {
        if kind == .dictationStarted { controlSequence &+= 1 }
        samplePerformance()
        diagnostics.mark(kind, at: ProcessInfo.processInfo.systemUptime - diagnosticsBegan)
    }

    /// Records a finished job, stamped with the time it finished.
    func recordPerformance(_ job: PerformanceJob) {
        var job = job
        job.elapsedSeconds = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.record(job)
    }

    /// Counts and state only; transcript and field contents never enter diagnostics.
    var recoveryDiagnostics: [String: Any] {
        [
            "attemptState": dictation.currentAttempt?.state.rawValue ?? "none",
            "attemptPending": dictation.isActive || dictation.isPending,
            "pendingAudioJobs": transcriber.jobs.count + (transcriber.processing == nil ? 0 : 1),
            "recoveryRunning": dictation.recoveryRunning,
            "cleanupPending": cleanup.pendingCount,
            "cleanupBufferedRows": cleanup.bufferedRowCount,
            "cleanupRequested": cleanup.cleanupRequestedCount,
            "cleanupCompleted": cleanup.cleanupCompletedCount,
            "cleanupApplied": cleanup.cleanupAppliedCount,
            "cleanupBypassed": cleanup.cleanupBypassedCount,
            "cleanupOutcomes": cleanup.cleanupOutcomeCounts
        ]
    }

    func recordEvent(_ kind: CaptureEventKind, _ detail: String, duration: Double? = nil, session: String? = nil) {
        let marker: PerformanceEventKind?
        switch kind {
        case .started: marker = .ambientStarted
        case .sleep: marker = .sleep
        case .deviceChange: marker = .deviceChange
        case .audioGap: marker = .audioGap
        case .processingError: marker = .processingFailed
        default: marker = nil
        }
        if let marker { markPerformance(marker) }
        let store = library.store
        let event = CaptureEvent(sessionID: session ?? timeline.sessionID, kind: kind.rawValue, detail: detail, durationSeconds: duration)
        let write = storeExecutor.submit { try store?.appendEvent(event) }
        Task {
            do { _ = try await write.value; library.refreshEvents() }
            catch { notice = "Could not save capture event: \(error.localizedDescription)" }
        }
    }

    func checkModelUpdates() {
        guard !checkingModels else { return }
        checkingModels = true
        let current = modelUpdates
        modelCheck = Task {
            let results = await withTaskGroup(of: (Int, ModelUpdate).self) { group in
                for (index, model) in current.enumerated() { group.addTask { (index, await model.check()) } }
                var rows: [(Int, ModelUpdate)] = []
                for await row in group { rows.append(row) }
                return rows.sorted { $0.0 < $1.0 }.map(\.1)
            }
            modelUpdates = results
            if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: JotDefaultsKey.modelUpdateChecks) }
            checkingModels = false; modelCheck = nil
        }
    }
}
