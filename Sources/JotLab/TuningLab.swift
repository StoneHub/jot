import Foundation
import JotCore
import JotEngine

/// `jot lab`: runs one recording through the real listening path once per recognition run its variants need, then
/// builds every variant's rows from that run's words, the offline speaker pass, and the variant's grouping settings.
/// It works in its own process with its own settings and a temporary store, so the running app, its capture, history
/// and preferences are never touched.
@MainActor
struct TuningLab {
    let audio: URL
    let variants: [LabVariant]
    let captions: [LabCaptions.Cue]?
    /// Working files (the run's store, the pass's copy of the audio) go here, outside the output folder.
    let scratch: URL
    /// The settings each variant starts from: the app's current values, read and never written.
    let base: UserDefaults?
    let log: (String) -> Void

    func run() async throws -> [LabVariantResult] {
        let samples = try AudioClock.resample(audio)
        let audioSeconds = AudioClock.seconds(samples: samples.count)
        let runs = LabVariant.recognitionRuns(variants)
        log(String(format: "Audio: %.1f s. %d variants in %d recognition runs.", audioSeconds, variants.count, runs.count))
        // The pass depends only on the audio, so every run shares it.
        log("Speaker pass…")
        let pass = try await speakerPass(samples)
        log(String(format: "Speaker pass: %d speakers in %.1f s.", Set(pass.segments.map(\.speaker)).count, pass.processingSeconds))
        var results: [LabVariantResult] = []
        for (number, group) in runs.enumerated() {
            let settings = try LabSettings(base: base, variant: group[0])
            log("Run \(number + 1): recognizing for \(group.map(\.name).joined(separator: ", "))…")
            let recognized = try await recognize(samples, settings: settings.value)
            log(String(format: "Run %d: %d rows in %.1f s.", number + 1, recognized.rows.count, recognized.seconds))
            for variant in group {
                let tuning = try settings.tuning(for: variant)
                let live = TranscriptGrouping.speakers(words: recognized.words, tuning: tuning)
                let passSpeakers = pass.segments.isEmpty ? nil : SpeakerPassRelabel.speakers(words: recognized.words, segments: pass.segments, tuning: tuning)
                let rows = try LabRows.rows(rows: recognized.rows, words: recognized.words, readable: recognized.readable,
                    liveSpeakers: live, passSpeakers: passSpeakers)
                var score = captions.map { LabScore(rows: rows, captions: $0) }
                if let captions {
                    score?.liveSpeakers = try LabSpeakerScore(words: recognized.words, speakers: live, captions: captions)
                    if let passSpeakers {
                        score?.passSpeakers = try LabSpeakerScore(words: recognized.words, speakers: passSpeakers, captions: captions)
                    }
                }
                results.append(LabVariantResult(name: variant.name, settings: variant.settings, recognitionRun: number + 1, rows: rows,
                    paragraphs: LabRows.paragraphs(rows, tuning: tuning),
                    timings: .init(audioSeconds: audioSeconds, recognitionSeconds: recognized.seconds, speakerPassSeconds: pass.processingSeconds),
                    score: score, cleanupOutcomes: recognized.cleanupOutcomes))
            }
        }
        return results
    }

    private struct Recognized {
        var rows: [Transcript]
        var words: [StoredWord]
        var readable: [String: String]
        var seconds: Double
        var cleanupOutcomes: [String: Int]
    }

    /// The microphone's path without the microphone: 0.2-second drains, each with the RMS of its last tap buffer, into a
    /// fresh session on a temporary store, as `JotRecoveryChecks --quiet-cpu` drives it. Cleanup runs when the variant has it on.
    private func recognize(_ samples: [Float], settings: JotSettings) async throws -> Recognized {
        let directory = scratch.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let service = SpeechService(dependencies: .init(
            infer: { pipeline, job, tuning in try await pipeline.infer(job, tuning: tuning) },
            deliver: { _, _ in .init(verified: true, path: "lab", outcome: "verified", targetApp: "jot-lab", targetPID: 0, role: "AXTextField", subrole: nil) },
            now: { Date() }), settings: settings)
        // The lab keeps no session audio of its own: it runs the speaker pass on the recording itself.
        service.keepAudioForSpeakerPass = false
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        defer { service.shutdown() }
        try await service.pipeline.prepare()
        do {
            let recognized = try await feed(samples, into: service, store: store)
            await service.pipeline.unload()
            return recognized
        } catch {
            await service.pipeline.unload()
            throw error
        }
    }

    private func feed(_ samples: [Float], into service: SpeechService, store: TranscriptStore) async throws -> Recognized {
        let began = ContinuousClock.now
        service.beginRecoveryVerification(store: store, startedAt: Date())
        guard let session = service.timeline.activeSessionID else { throw LabError.invalid("The lab could not start a listening session.") }
        let packet = AudioClock.samples(seconds: 0.2)
        let tapBuffer = 1_365
        for lower in stride(from: 0, to: samples.count, by: packet) {
            let chunk = Array(samples[lower..<min(lower + packet, samples.count)])
            let tail = chunk.suffix(tapBuffer)
            let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(max(1, tail.count))).squareRoot()
            service.ingestRecoveryVerification(samples: chunk, rms: rms)
            await service.waitForRecoveryVerification()
        }
        service.flushRecoveryVerification()
        await service.waitForRecoveryVerification()
        let seconds = Double(began.duration(to: .now) / .milliseconds(1)) / 1_000
        return Recognized(rows: try store.session(id: session).filter { $0.mode == "ambient" }, words: try store.words(sessionID: session),
            readable: try store.readableTexts(sessionID: session), seconds: seconds, cleanupOutcomes: service.cleanup.cleanupOutcomeCounts)
    }

    /// The offline pass over the whole recording, from a copy the pass deletes when it is done.
    private func speakerPass(_ samples: [Float]) async throws -> SpeakerPassResult {
        let file = scratch.appendingPathComponent("pass-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: file) }
        try samples.withUnsafeBufferPointer { try Data(buffer: $0).write(to: file) }
        let pass = SpeakerPass()
        do {
            let result = try await pass.run(url: file)
            await pass.unload()
            return SpeakerPassRelabel.renumbered(result)
        } catch {
            await pass.unload()
            throw error
        }
    }
}

/// One recognition run's settings: in memory, seeded with the app's current values and the run's recognition settings.
/// Grouping stays at the app's values while recording, so the variants that share the run do not depend on their order.
@MainActor
struct LabSettings {
    let value: JotSettings
    private let base: UserDefaults?

    init(base: UserDefaults?, variant: LabVariant) throws {
        self.base = base
        let defaults = MemoryDefaults()
        // The revision too, so the copy is not treated as an install that predates the app's setting resets.
        for key in JotSettings.definitions.map(\.key) + [JotSettings.revisionKey] {
            if let saved = base?.object(forKey: key) { defaults.set(saved, forKey: key) }
        }
        value = JotSettings(defaults: defaults)
        try variant.recognitionSettings.apply(to: value)
    }

    /// The variant's grouping over the base values: a grouping setting another variant of the run changed does not carry over.
    func tuning(for variant: LabVariant) throws -> TranscriptionTuning {
        for key in LabVariant.groupingKeys {
            if let saved = base?.object(forKey: key) { value.defaults.set(saved, forKey: key) } else { try value.reset(key) }
        }
        try variant.apply(to: value)
        return value.tuning
    }
}
