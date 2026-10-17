import Foundation
import JotCore
import JotEngine

/// `JotRecoveryChecks --quiet-cpu <speech files…>` measures the real speech pipeline through the listening path the microphone uses: 0.2-second drains with the capture RMS gate, bounded chunks, recognition, speaker attribution and the store, with cleanup off. For quiet workloads and for a conversation built from the given speech files it prints process CPU seconds per audio minute (the kernel's count, which `ps` and `jot status` agree with), recognition time of the jobs that produced text, and the saved rows and words with their speaker probabilities, so a change can be compared with its baseline on the same Mac. `JOT_QUIET_CPU_REALTIME=1` paces the drains on the wall clock; `JOT_QUIET_CPU_SECONDS`, `JOT_QUIET_CPU_GAP` and `JOT_QUIET_CPU_REPEATS` size the quiet workloads, the conversation's long quiet pause and the repeats. Pass only synthetic fixtures such as `say` output; never private recordings.
extension RecoveryFlowChecks {
    /// Deterministic white noise at a fixed RMS, standing in for a room.
    static func noise(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        let scale = rms * Float(3.0).squareRoot()
        return (0..<AudioClock.samples(seconds: seconds)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * scale
        }
    }

    @MainActor final class JobTally {
        var jobs = 0
        var noSpeech = 0
        var speechSeconds: [Double] = []
    }

    struct ListeningRun {
        var cpuSeconds = 0.0
        var wallSeconds = 0.0
        var audioSeconds = 0.0
        var jobs = 0
        var noSpeech = 0
        var speechSeconds: [Double] = []
        var rows: [Transcript] = []
        var words: [StoredWord] = []
        var cpuPerAudioMinute: Double { cpuSeconds / audioSeconds * 60 }
    }

    /// Feeds the samples as 0.2-second microphone drains, each with the RMS of its last tap buffer, into a fresh session on a temporary store.
    @MainActor static func listen(_ service: SpeechService, tally: JobTally, to samples: [Float]) async throws -> ListeningRun {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-quiet-cpu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        tally.jobs = 0; tally.noSpeech = 0; tally.speechSeconds = []
        service.beginRecoveryVerification(store: store, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let session = service.timeline.activeSessionID!
        let packet = AudioClock.samples(seconds: 0.2)
        let tapBuffer = 1_365
        let realTime = ProcessInfo.processInfo.environment["JOT_QUIET_CPU_REALTIME"] == "1"
        var run = ListeningRun()
        let cpuBegan = kernelCPUSeconds()
        let began = ContinuousClock.now
        for lower in stride(from: 0, to: samples.count, by: packet) {
            let chunk = Array(samples[lower..<min(lower + packet, samples.count)])
            let tail = chunk.suffix(tapBuffer)
            let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(max(1, tail.count))).squareRoot()
            service.ingestRecoveryVerification(samples: chunk, rms: rms)
            await service.waitForRecoveryVerification()
            if realTime {
                try await Task.sleep(until: began + .seconds(AudioClock.seconds(samples: lower + chunk.count)), clock: .continuous)
            }
        }
        service.flushRecoveryVerification()
        await service.waitForRecoveryVerification()
        run.cpuSeconds = kernelCPUSeconds() - cpuBegan
        run.wallSeconds = Double(began.duration(to: .now) / .milliseconds(1)) / 1_000
        run.audioSeconds = AudioClock.seconds(samples: samples.count)
        run.jobs = tally.jobs
        run.noSpeech = tally.noSpeech
        run.speechSeconds = tally.speechSeconds
        run.rows = try store.session(id: session)
        run.words = try store.words(sessionID: session)
        return run
    }

    @MainActor static func profileQuietListening(_ files: [URL]) async throws {
        let voices = try files.map { try AudioClock.resample($0) }
        precondition(!voices.isEmpty, "Pass at least one synthetic speech file after --quiet-cpu")
        let environment = ProcessInfo.processInfo.environment
        let tally = JobTally()
        let service = SpeechService(dependencies: .init(
            infer: { pipeline, job, tuning in
                let output = try await pipeline.infer(job, tuning: tuning)
                tally.jobs += 1
                if output.text.isEmpty { tally.noSpeech += 1 } else { tally.speechSeconds.append(output.processingSeconds) }
                return output
            },
            deliver: { _, _ in .init(verified: true, path: "synthetic", outcome: "verified", targetApp: "synthetic-test", targetPID: 0, role: "AXTextField", subrole: nil) },
            now: { Date() }))
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        try await service.pipeline.prepare()
        defer { service.shutdown() }
        // Warm the models so first-use compilation is not billed to a workload.
        _ = try await listen(service, tally: tally, to: voices[0] + noise(seconds: 2, rms: 0.0005, seed: 9))

        let room: Float = 0.0005, fan: Float = 0.004
        let gap = Double(environment["JOT_QUIET_CPU_GAP"] ?? "") ?? 30
        // Utterances alternate between the files' voices over fan noise, and every third is faint, 24 dB down. The pauses after them cycle through a breath, a long quiet room below the capture gate, and 20 seconds of fan noise, so speaker labels must survive long quiet.
        let pauses: [(seconds: Double, rms: Float)] = [(1.2, fan), (gap, room), (1.2, fan), (20, fan)]
        var conversation: [Float] = noise(seconds: 4, rms: fan, seed: 1)
        for (index, voice) in voices.enumerated() {
            let gain: Float = index % 3 == 2 ? 0.063 : 1
            let bed = noise(seconds: AudioClock.seconds(samples: voice.count), rms: fan, seed: UInt64(10 + index))
            conversation += zip(voice, bed).map { $0 * gain + $1 }
            let pause = pauses[index % pauses.count]
            conversation += noise(seconds: pause.seconds, rms: pause.rms, seed: UInt64(20 + index))
        }
        let quietSeconds = Double(environment["JOT_QUIET_CPU_SECONDS"] ?? "") ?? 120
        let workloads: [(String, [Float])] = [
            ("quiet room, RMS 0.0005 below the capture gate", noise(seconds: quietSeconds, rms: room, seed: 2)),
            ("fan noise, RMS 0.004 above the capture gate", noise(seconds: quietSeconds, rms: fan, seed: 3)),
            ("conversation with pauses and faint speech", conversation)
        ]
        let repeats = max(1, Int(environment["JOT_QUIET_CPU_REPEATS"] ?? "") ?? 3)
        for (name, samples) in workloads {
            var runs: [ListeningRun] = []
            for _ in 0..<repeats { runs.append(try await listen(service, tally: tally, to: samples)) }
            let cpu = runs.map { String(format: "%.2f", $0.cpuPerAudioMinute) }.joined(separator: " / ")
            let last = runs.last!
            print(String(format: "QUIET CPU: %@: %.1f audio s, CPU s per audio minute %@, wall %.1f s, %d jobs, %d without speech",
                name, last.audioSeconds, cpu, last.wallSeconds, last.jobs, last.noSpeech))
            let speech = runs.flatMap(\.speechSeconds).sorted()
            if !speech.isEmpty {
                print(String(format: "QUIET CPU SPEECH JOBS: %d, recognition median %.3f s, max %.3f s",
                    speech.count, speech[speech.count / 2], speech.last!))
            }
            for row in last.rows {
                print(String(format: "QUIET CPU ROW: [%.2f-%.2f] %@: %@", row.startSeconds, row.endSeconds, row.speakerID ?? "none", row.text))
            }
            for word in last.words {
                print(String(format: "QUIET CPU WORD: [%.2f] %@ %@", word.startSeconds, word.word,
                    word.probabilities.map { String(format: "%.3f", $0) }.joined(separator: ",")))
            }
        }
    }
}
