import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// What the stand-in speaker pass saw, recorded from whichever thread runs it.
    final class PassLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var entries: [String] { lock.withLock { recorded } }
        func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    }

    /// Session audio kept for tuning. With keepTuningAudio off, the pass gets the session's file and nothing else is kept. On,
    /// a WAV of the same samples is written before the pass reads its file, the pass still deletes that file, and a kept file
    /// past 30 days goes. A copy that fails is logged and the pass goes ahead. The real pass needs the speaker models, so a
    /// stand-in reads and deletes the file the way it does.
    @MainActor static func checkTuningAudio(directory: URL) async throws {
        let folder = directory.appendingPathComponent("tuning-audio-check")
        let audio = folder.appendingPathComponent("audio"), kept = folder.appendingPathComponent("tuning-audio")
        let store = try TranscriptStore(directory: folder)
        let service = SpeechService(dependencies: .init(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init))
        service.keepAudioForSpeakerPass = false
        service.beginRecoveryVerification(store: store)
        defer { service.shutdown(); try? service.settings.reset(JotSettings.keepTuningAudio) }
        service.speakers.tuningAudioDirectory = kept
        let passes = PassLog()
        service.speakers.runPass = { url in
            defer { try? FileManager.default.removeItem(at: url) }
            let id = url.deletingPathExtension().lastPathComponent
            let count = try Data(contentsOf: url).count / MemoryLayout<Float>.size
            let keptFirst = FileManager.default.fileExists(atPath: TuningAudio.url(sessionID: id, in: kept).path)
            passes.append("\(id): \(count) samples, WAV before the pass: \(keptFirst)")
            return SpeakerPassResult(segments: [], speakers: [:], durationSeconds: AudioClock.seconds(samples: count), processingSeconds: 0)
        }
        func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        let samples = (0..<40_000).map { Float($0 % 400) / 400 - 0.5 }
        func endSession(_ id: String) async throws {
            let file = SessionAudioFile(sessionID: id, directory: audio)
            for start in stride(from: 0, to: samples.count, by: 8_000) { file.append(Array(samples[start..<start + 8_000])) }
            service.speakers.enqueuePass(file)
            while service.speakers.hasPendingPasses { try await Task.sleep(for: .milliseconds(5)) }
            await service.waitForRecoveryVerification()
        }

        service.settings.set(JotSettings.keepTuningAudio, false)
        try await endSession("off")
        precondition(passes.entries == ["off: 40000 samples, WAV before the pass: false"], "The pass did not get the whole session: \(passes.entries)")
        precondition(names(kept).isEmpty, "Audio was kept for tuning with the setting off: \(names(kept))")
        precondition(names(audio).isEmpty, "The pass did not delete its file: \(names(audio))")

        // A file kept 31 days ago goes when the next one is added.
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let old = TuningAudio.url(sessionID: "old", in: kept)
        try Data(count: 8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date() - 31 * 24 * 60 * 60], ofItemAtPath: old.path)
        service.settings.set(JotSettings.keepTuningAudio, true)
        try await endSession("on")
        precondition(passes.entries.last == "on: 40000 samples, WAV before the pass: true", "The WAV was not written before the pass read its file: \(passes.entries)")
        precondition(names(audio).isEmpty, "The pass did not delete its file: \(names(audio))")
        precondition(names(kept) == ["on.wav"], "Kept files after the pass: \(names(kept))")
        // TuningAudioTests reads the samples back with AVAudioFile; here a 44-byte header and two bytes a sample give the session's length.
        let wav = try Data(contentsOf: TuningAudio.url(sessionID: "on", in: kept))
        precondition(wav.prefix(4) == Data("RIFF".utf8) && wav.count == 44 + 2 * samples.count, "The WAV is not the session's length: \(wav.count) bytes")
        let pruned = try store.events(sessionID: "old")
        precondition(pruned.contains { $0.kind == "audio_discarded" }, "Deleting the 31-day-old file was not logged: \(pruned.map(\.detail))")

        // Deleting a session deletes its kept WAV, and a session deleted before its pass keeps nothing.
        try await service.deleteSession("on")
        precondition(names(kept).isEmpty, "Deleting the session left its WAV: \(names(kept))")
        try await service.deleteSession("gone")
        try await endSession("gone")
        precondition(passes.entries.last == "gone: 40000 samples, WAV before the pass: false" && names(kept).isEmpty,
                     "A session deleted before its pass still kept its audio: \(names(kept)), \(passes.entries)")

        // A copy that cannot be written leaves the pass as it was.
        let blocked = folder.appendingPathComponent("not-a-folder")
        try Data().write(to: blocked)
        service.speakers.tuningAudioDirectory = blocked
        try await endSession("blocked")
        precondition(passes.entries.last == "blocked: 40000 samples, WAV before the pass: false", "The pass did not get the whole session after a failed copy: \(passes.entries)")
        let events = try store.events(sessionID: "blocked")
        precondition(events.contains { $0.kind == "processing_error" && $0.detail.contains("for tuning") }, "The failed copy was not logged: \(events.map(\.detail))")
        precondition(events.contains { $0.kind == "speaker_pass" }, "The pass did not finish after the copy failed: \(events.map(\.detail))")
        print("PASS: with keepTuningAudio off the pass gets the session's file and nothing is kept; on, a 16 kHz mono 16-bit WAV of the same length is written before the pass reads and deletes its file, a kept file past 30 days goes, deleting a session deletes its WAV, and a failed copy is logged without changing the pass.")
    }
}
