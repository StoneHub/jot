import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// A speaker pass and a Regroup over a long session run while listening continues. The longest main-actor gap stays within 50 ms of the same run's gap with no relabel, and a microphone that holds one second never overflows into an audio gap.
    @MainActor static func checkSpeakerPassKeepsMainFree(directory: URL) async throws {
        let folder = directory.appendingPathComponent("long-session")
        let store = try TranscriptStore(directory: folder)
        // The real queue holds eight seconds; one second here makes a stall of a second or more lose audio.
        let microphone = ClockedMicrophone(holdingSeconds: 1)
        var dependencies = SpeechServiceDependencies(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init)
        dependencies.makeMicrophone = { microphone }
        let service = SpeechService(dependencies: dependencies)
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.speakers.speakerStore = try SpeakerPassStore(sharing: store)
        service.beginRecoveryVerification(store: store)
        defer { service.shutdown() }

        // 3,000 cleaned rows of ten words, each row three seconds like a live block.
        let session = "seeded"
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        let text = vocabulary.joined(separator: " ")
        var rows: [Transcript] = []
        var words: [StoredWord] = []
        for index in 0..<3_000 {
            let start = Double(index) * 3
            let row = Transcript(sessionID: session, startedAt: started, startSeconds: start, endSeconds: start + 2.95, text: text, mode: "ambient")
            rows.append(row)
            for (position, word) in vocabulary.enumerated() {
                let wordStart = start + Double(position) * 0.3
                words.append(StoredWord(transcriptID: row.id, position: position, word: word, startSeconds: wordStart, endSeconds: wordStart + 0.25, probabilities: []))
            }
        }
        for row in rows {
            try store.append(row)
        }
        for start in stride(from: 0, to: words.count, by: 15_000) {
            try store.appendWords(Array(words[start..<min(start + 15_000, words.count)]))
        }
        let readable = Array(repeating: "Alpha bravo charlie delta echo foxtrot golf hotel india juliet.", count: rows.count)
        let seeded = try store.setReadablePhrase(readable, for: rows)
        precondition(seeded, "The long session was not seeded")
        // 1,500 six-second turns rotating three voices. Each turn starts halfway through a row, so the pass splits every other row. Regroup from the same segments then relabels all 4,500 rows in place.
        let segments = (0..<1_500).map { (turn: Int) -> (speaker: String, start: Double, end: Double) in
            let start = Double(turn) * 6 + 1.5
            return (speaker: "S\(turn % 3 + 1)", start: start, end: start + 6)
        }
        let pass = SpeakerPassResult(segments: segments, speakers: ["S1": [1], "S2": [2], "S3": [3]], durationSeconds: 9_000, processingSeconds: 1)

        // Listening goes on. Every 5 ms the ticker drains the microphone and does what a recognized block does: it saves a row and its word, adds the row to Live, and folds it into the recent rows and the Sessions list. It returns the longest gap between wakes beyond the 5 ms it sleeps.
        let listening = service.timeline.activeSessionID!
        func listen() -> Task<Duration, Never> {
            // The clock starts before the ticker's first run, so a stall that keeps it from starting is counted too.
            let tickerStarted = ContinuousClock.now
            return Task { @MainActor () -> Duration in
                var longest = Duration.zero
                var last = tickerStarted
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = ContinuousClock.now
                    longest = max(longest, last.duration(to: now) - .milliseconds(5))
                    last = now
                    service.drainAudio()
                    service.transcriber.kick()
                    ticks += 1
                    let start = Double(ticks) * 0.01
                    let row = Transcript(sessionID: listening, startedAt: started, startSeconds: start, endSeconds: start + 0.005, text: "tick", mode: "ambient")
                    let write = service.storeExecutor.submit {
                        try store.append(row)
                        try store.appendWords([StoredWord(transcriptID: row.id, position: 0, word: "tick", startSeconds: start, endSeconds: start + 0.005, probabilities: [])])
                    }
                    Task { @MainActor in
                        guard (try? await write.value) != nil else { return }
                        service.library.appendLive([row])
                        service.library.didSave([row])
                    }
                }
                return longest
            }
        }
        try microphone.start()
        let quiet = listen()
        try await Task.sleep(for: .seconds(1))
        quiet.cancel()
        let baseline = await quiet.value
        let ticker = listen()
        try await Task.sleep(for: .milliseconds(20))
        let began = ContinuousClock.now
        await service.speakers.apply(pass, session: session, truncated: false)
        let passTime = began.duration(to: .now)
        try await service.regroupSession(session)
        let total = began.duration(to: .now)
        ticker.cancel()
        let gap = await ticker.value
        await service.waitForRecoveryVerification()
        let events = try store.events(limit: 200)
        let rowCount = try store.session(id: session).count
        let cleanedCount = try store.readableTexts(sessionID: session).count
        precondition(events.contains { $0.kind == "speaker_pass" }, "The speaker pass did not finish: \(service.notice)")
        precondition(rowCount == 4_500, "Every other row should have split in two, not \(rowCount) rows")
        precondition(cleanedCount == 4_500, "A relabeled row lost its cleaned text: \(cleanedCount) cleaned rows")
        let allowed = max(.milliseconds(50), baseline + .milliseconds(50))
        func milliseconds(_ duration: Duration) -> String { String(format: "%.1f ms", Double(duration / .microseconds(1)) / 1_000) }
        func seconds(_ duration: Duration) -> String { String(format: "%.2f s", Double(duration / .milliseconds(1)) / 1_000) }
        let timing = "longest main-actor gap \(milliseconds(gap)) against \(milliseconds(baseline)) with no relabel, pass \(seconds(passTime)), pass and Regroup \(seconds(total)), \(service.droppedSeconds) s of audio dropped"
        print("Speaker pass over 3,000 rows: \(timing).")
        precondition(gap < allowed, "The main actor stalled during the pass: \(timing)")
        precondition(service.droppedSeconds == 0, "Listening dropped \(service.droppedSeconds) s of audio during the pass")
        precondition(!events.contains { $0.kind == "audio_gap" }, "An audio gap was recorded during the pass")
        print("PASS: a speaker pass and Regroup over 3,000 rows keep the main actor's longest gap within 50 ms of listening alone, and a microphone holding one second drops no audio.")
    }
}
