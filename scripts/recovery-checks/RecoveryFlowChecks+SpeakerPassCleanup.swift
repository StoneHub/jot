import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// Holds phrase cleanup until opened, and says when a phrase is waiting at it.
    final class CleanupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var held = false
        var holding: Bool { lock.withLock { held } }
        func close() { lock.withLock { closed = true } }
        func open() { lock.withLock { closed = false } }
        func pass() async throws {
            guard lock.withLock({ closed }) else { return }
            lock.withLock { held = true }
            defer { lock.withLock { held = false } }
            while lock.withLock({ closed }) { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    /// A finished session keeps its cleaned text through the speaker pass and takes the pass's speakers; Regroup from the stored pass then changes nothing. Regroup pressed while a session's last phrase is still being cleaned keeps the cleaned text too. Regroup pressed before the pass has stored its segments ends with the pass's speakers and names, even when Regroup writes after the pass.
    @MainActor static func checkSpeakerPassKeepsCleanup(directory: URL) async throws {
        let folder = directory.appendingPathComponent("speaker-pass")
        let store = try TranscriptStore(directory: folder)
        let probe = Probe()
        let gate = CleanupGate()
        // One row per three-second block, with word times relative to the block as the recognizer reports them.
        let blocks: [[(word: String, start: Double, end: Double)]] = [
            [("so", 0, 0.4), ("we", 0.5, 0.9), ("should", 1.0, 1.4), ("ship", 2.0, 2.4), ("it", 2.5, 2.9)],
            [("on", 0.1, 0.4), ("friday", 0.5, 1.0), ("then", 1.1, 1.4), ("ok", 1.6, 2.0)]]
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                guard let index = job.samples.first.map(Int.init), index > 0 else {
                    return SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
                }
                let words = blocks[index - 1].map { AttributedWord(text: $0.word, start: $0.start, end: $0.end, probabilities: []) }
                let text = words.map(\.text).joined(separator: " ")
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + words[0].start, endSeconds: job.offset + words[words.count - 1].end, text: text, mode: "ambient")
                return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0, wordsByTranscript: [row.id: words])
            },
            deliver: { _, text in try probe.deliver(text) },
            now: { probe.now },
            cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { texts in
                    try await Task.sleep(for: .seconds(1))
                    try await gate.pass()
                    return texts.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                })
            }, intelligenceAvailability: { .available }))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = true
        service.speakers.speakerStore = try SpeakerPassStore(sharing: store)
        service.speakers.peopleStore = try PeopleStore(sharing: store)
        // A remembered voice that matches the pass's first speaker.
        _ = try service.speakers.peopleStore?.add(name: "Ada", embedding: [1])
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        /// Speaks both blocks into the running session, then ends it the way quiet does: its last block goes out as a final job, which hands the whole phrase to cleanup.
        func speakAndEndSession() -> String {
            let id = service.timeline.activeSessionID!
            for index in 1...2 {
                probe.now += 3
                service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            }
            service.timeline.rotateSession()
            service.transcriber.kick()
            return id
        }
        /// What cleanup did, for a failure message (#228): cleaned text refused because a relabel replaced its rows first counts as bypassed after a changed outcome; a timed-out or busy cleanup shows in the outcomes.
        func cleanupState(_ paragraphs: [Transcript]) -> String {
            let cleanup = service.cleanup
            let outcomes = cleanup.cleanupOutcomeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "speakers \(paragraphs.map(\.speakerID)); cleanup applied \(cleanup.cleanupAppliedCount), bypassed \(cleanup.cleanupBypassedCount), outcomes [\(outcomes)]; notice \(service.notice)"
        }
        let id = speakAndEndSession()
        service.library.showLive(id)
        // The first voice gives way to the second inside the first row, between "should" and "ship". Cleanup is still running when the pass arrives.
        let pass = SpeakerPassResult(segments: [("S1", 0, 1.7), ("S2", 1.7, 6)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 6, processingSeconds: 0.1)
        await service.speakers.apply(pass, session: id, truncated: false)
        // Live reloads after the pass names the voice, not only after the relabel.
        await service.library.waitForReads()
        let named = service.library.live.paragraphs.filter { $0.speakerID == "speaker-1" }.map(\.speakerLabel)
        precondition(!named.isEmpty && named.allSatisfy { $0 == "Ada" }, "Live did not show the name the pass recognized: \(named), \(service.notice)")
        await service.waitForRecoveryVerification()
        let expected = ["So we should", "ship it on friday then ok."]
        let speakers = ["speaker-1", "speaker-2"]
        let paragraphs = await service.library.sessionParagraphs(id)
        precondition(paragraphs.map(\.text) == expected, "The speaker pass lost cleaned text: \(paragraphs.map(\.text)); \(cleanupState(paragraphs))")
        precondition(paragraphs.map(\.speakerID) == speakers, "The speaker pass labels were not applied: \(paragraphs.map(\.speakerID))")
        let events = try store.events(sessionID: id)
        precondition(events.contains { $0.kind == "speaker_pass" }, "The speaker pass recorded no event: \(service.notice)")
        let rows = try store.session(id: id).map(\.id)
        try await service.regroupSession(id)
        let regrouped = await service.library.sessionParagraphs(id)
        precondition(regrouped.map(\.text) == expected && regrouped.map(\.speakerID) == speakers, "Regroup from the stored pass changed the session: \(regrouped.map(\.text))")
        let regroupedRows = try store.session(id: id).map(\.id)
        precondition(regroupedRows == rows, "Regroup from the stored pass replaced rows it only needed to keep")
        print("PASS: the speaker pass keeps a finished session's cleaned text, splits a row where the speaker changes, shows the voice it recognized in Live, and Regroup from the pass changes nothing.")

        // A second session ends the same way and has the same pass stored. Regroup is pressed while its phrase is still being cleaned.
        let second = speakAndEndSession()
        try service.speakers.speakerStore?.replace(sessionID: second, result: SpeakerPassRelabel.renumbered(pass))
        while !service.cleanup.isCleaning(session: second) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await service.regroupSession(second)
        await service.waitForRecoveryVerification()
        let duringCleanup = await service.library.sessionParagraphs(second)
        precondition(duringCleanup.map(\.text) == expected, "Regroup during cleanup lost cleaned text: \(duringCleanup.map(\.text)); \(cleanupState(duringCleanup))")
        precondition(duringCleanup.map(\.speakerID) == speakers, "Regroup during cleanup did not apply the pass: \(duringCleanup.map(\.speakerID))")
        print("PASS: Regroup pressed while a session's last phrase is being cleaned waits for it and keeps the cleaned text.")

        // A third session ends the same way with no pass stored yet. Regroup is pressed while its phrase is held in cleanup, so it waits for the session to settle. The phrase is let go, and once the session settles the pass stores its segments, relabels and names the voice while Regroup still waits for its next look. Regroup then writes last.
        gate.close()
        let third = speakAndEndSession()
        while !gate.holding {
            try await Task.sleep(for: .milliseconds(1))
        }
        let storedBeforePress = try service.speakers.speakerStore?.segments(sessionID: third) ?? []
        precondition(storedBeforePress.isEmpty, "The pass's segments were stored before Regroup was pressed")
        let early = Task { try await service.regroupSession(third) }
        while !service.library.isRelabeling {
            try await Task.sleep(for: .milliseconds(1))
        }
        gate.open()
        while !service.sessionIsSettled(third) {
            try await Task.sleep(for: .milliseconds(1))
        }
        await service.speakers.apply(pass, session: third, truncated: false)
        precondition(service.library.isRelabeling, "Regroup finished before the pass relabeled, so it did not write last: \(service.notice)")
        try await early.value
        let afterEarly = await service.library.sessionParagraphs(third)
        precondition(afterEarly.map(\.speakerID) == speakers, "Regroup pressed before the pass stored its segments replaced the pass's speakers: \(afterEarly.map(\.speakerID)), \(afterEarly.map(\.text))")
        precondition(afterEarly.map(\.text) == expected, "Regroup pressed before the pass lost cleaned text: \(afterEarly.map(\.text)); \(cleanupState(afterEarly))")
        let earlyNames = afterEarly.map(\.speakerLabel)
        precondition(earlyNames == ["Ada", nil], "Regroup pressed before the pass stored its segments moved the name the pass recognized: \(earlyNames)")
        precondition(service.notice == "Session regrouped from the speaker pass.", "Regroup pressed before the pass did not regroup from it: \(service.notice)")
        print("PASS: Regroup pressed before the speaker pass stores its segments reads them after it waits, so the session keeps the pass's speakers and names.")
    }
}
