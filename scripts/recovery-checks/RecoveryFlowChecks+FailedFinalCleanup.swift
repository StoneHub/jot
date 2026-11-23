import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// A session whose final block fails still gets its phrase cleaned (#228). Before, the rows stayed buffered: the session
    /// counted as settled, a Regroup split its rows, and the cleanup flushed by the next session's first row was refused
    /// because the rows it was made from were gone, so the cleaned text was lost.
    @MainActor static func checkFailedFinalKeepsCleanup(directory: URL) async throws {
        enum SyntheticFailure: Error { case recognition }
        let probe = Probe()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("failed-final"), key: .scratch)
        let blocks: [[(word: String, start: Double, end: Double)]] = [
            [("so", 0, 0.4), ("we", 0.5, 0.9), ("should", 1.0, 1.4), ("ship", 2.0, 2.4), ("it", 2.5, 2.9)],
            [("on", 0.1, 0.4), ("friday", 0.5, 1.0), ("then", 1.1, 1.4), ("ok", 1.6, 2.0)]]
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                guard let index = job.samples.first.map(Int.init), index > 0 else {
                    if probe.failFinal { throw SyntheticFailure.recognition }
                    return SpeechOutput(transcripts: [], text: "", processingSeconds: 0)
                }
                let words = blocks[index - 1].map { AttributedWord(text: $0.word, start: $0.start, end: $0.end, probabilities: [0.9, 0, 0, 0]) }
                let text = words.map(\.text).joined(separator: " ")
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                    startSeconds: job.offset + words[0].start, endSeconds: job.offset + words[words.count - 1].end, text: text, mode: "ambient")
                return SpeechOutput(transcripts: [row], text: text, processingSeconds: 0, wordsByTranscript: [row.id: words])
            },
            deliver: { _, text in try probe.deliver(text) },
            now: { probe.now },
            cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { texts in
                    try await Task.sleep(for: .milliseconds(500))
                    return texts.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                })
            }, intelligenceAvailability: { .available }))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = true
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let id = service.timeline.activeSessionID!
        for index in 1...2 {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
        }
        // The session ends the way quiet does, but its final block fails in recognition.
        probe.failFinal = true
        service.timeline.rotateSession()
        service.transcriber.kick()
        while service.transcriber.recognitionFailures == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(service.cleanup.isCleaning(session: id), "A failed final block left the session's phrase buffered, so Regroup would not wait for its cleanup")
        precondition(!service.sessionIsSettled(id), "A session whose phrase is being cleaned counted as settled")
        try await service.regroupSession(id)
        await service.waitForRecoveryVerification()
        let paragraphs = await service.library.sessionParagraphs(id)
        precondition(paragraphs.map(\.text) == ["So we should ship it on friday then ok."], "Regroup after a failed final block lost cleaned text: \(paragraphs.map(\.text)); cleanup applied \(service.cleanup.cleanupAppliedCount), bypassed \(service.cleanup.cleanupBypassedCount); notice \(service.notice)")
        precondition(service.cleanup.cleanupAppliedCount == 1, "Cleanup ran \(service.cleanup.cleanupAppliedCount) times for one phrase")

        // The next session's first row no longer flushes the earlier session's phrase: it starts its own.
        probe.failFinal = false
        let next = service.timeline.activeSessionID!
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(1), count: 48_000), at: probe.now)
        service.timeline.rotateSession()
        service.transcriber.kick()
        await service.waitForRecoveryVerification()
        let nextParagraphs = await service.library.sessionParagraphs(next)
        precondition(nextParagraphs.map(\.text) == ["So we should ship it."], "The next session's phrase was not cleaned on its own: \(nextParagraphs.map(\.text))")
        precondition(service.cleanup.cleanupAppliedCount == 2 && service.cleanup.cleanupBypassedCount == 0, "A phrase was cleaned twice or refused: applied \(service.cleanup.cleanupAppliedCount), bypassed \(service.cleanup.cleanupBypassedCount)")
        print("PASS: a session whose final block fails still has its phrase cleaned before Regroup writes, and the next session's phrase is its own.")
    }
}
