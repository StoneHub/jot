import Combine
import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
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
}
