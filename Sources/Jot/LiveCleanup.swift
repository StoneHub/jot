import Foundation
import JotCore

/// What live cleanup needs from the service: the Live cleanup switch, the injected cleaner, the store it rewrites, and the screens it refreshes.
@MainActor
protocol LiveCleanupHost: AnyObject {
    var dependencies: SpeechServiceDependencies { get }
    var store: TranscriptStore? { get }
    var cleanUpTranscriptions: Bool { get }
    func sessionIsDeleted(_ id: String) -> Bool
    func replaceLive(texts: [String: String])
    func didClean(_ sources: [Transcript], texts: [String: String])
}

/// Rewrites saved recognition into readable text: live rows as whole phrases, one phrase at a time, and a held dictation's text before insertion.
@MainActor
final class LiveCleanup {
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var phraseCleanup = PhraseCleanup()
    private var cleanupQueue: [PhraseCleanup.Phrase] = []
    /// The session of the phrase the worker is cleaning now.
    private var runningSession: String?
    private let liveTranscriptCleanup = TranscriptCleanup()
    private let transcriptCleanup = TranscriptCleanup()
    // A live phrase carries up to 2000 bytes; measured on-device cleanup of that
    // length returns in about 9 seconds.
    static let livePhraseCleanupTimeout = Duration.seconds(12)
    // Dictation waits for cleanup like Live does; the deadline only keeps a stalled model from blocking every later press.
    static let dictationCleanupTimeout = livePhraseCleanupTimeout
    private(set) var cleanupRequestedCount = 0
    private(set) var cleanupCompletedCount = 0
    private(set) var cleanupAppliedCount = 0
    private(set) var cleanupBypassedCount = 0
    private(set) var cleanupOutcomeCounts: [String: Int] = [:]
    private unowned let host: LiveCleanupHost

    init(host: LiveCleanupHost) { self.host = host }

    /// A phrase worker is running; Install Update and the harness wait for it.
    var isRunning: Bool { !cleanupTasks.isEmpty }
    /// Phrases being cleaned or waiting, for the recovery diagnostics.
    var pendingCount: Int { cleanupTasks.count + cleanupQueue.count }
    /// Rows held until their phrase is complete.
    var bufferedRowCount: Int { phraseCleanup.pendingCount }

    /// True while a phrase of the session is being cleaned or waits in the queue. Rows still buffered for a phrase do not count: the session's final recognition job moves them into the queue.
    func isCleaning(session: String) -> Bool {
        runningSession == session || cleanupQueue.contains { $0.sources.first?.sessionID == session }
    }

    func scheduleCleanup(sources: [Transcript], final: Bool) {
        guard host.cleanUpTranscriptions else { phraseCleanup = PhraseCleanup(); return }
        for phrase in phraseCleanup.append(sources, final: final) {
            cleanupRequestedCount += 1
            if cleanupQueue.count < 8 { cleanupQueue.append(phrase) }
            else {
                cleanupBypassedCount += 1; cleanupCompletedCount += 1
                cleanupOutcomeCounts[CleanupResult.Outcome.busy.rawValue, default: 0] += 1
            }
        }
        guard cleanupTasks.isEmpty, !cleanupQueue.isEmpty else { return }
        let id = UUID()
        cleanupTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { cleanupTasks[id] = nil }
            while !Task.isCancelled, !cleanupQueue.isEmpty {
                let phrase = cleanupQueue.removeFirst()
                runningSession = phrase.sources.first?.sessionID
                defer { runningSession = nil }
                guard host.cleanUpTranscriptions, let session = phrase.sources.first?.sessionID,
                      !host.sessionIsDeleted(session) else {
                    cleanupBypassedCount += 1; cleanupCompletedCount += 1; continue
                }
                var cleanup = await host.dependencies.cleanup(liveTranscriptCleanup, [phrase.text], Self.livePhraseCleanupTimeout)
                // A timed-out generator may still be relinquishing the local model.
                // Retain the phrase briefly instead of dropping the next request.
                for _ in 0..<5 where cleanup.outcome == .busy && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    cleanup = await host.dependencies.cleanup(liveTranscriptCleanup, [phrase.text], Self.livePhraseCleanupTimeout)
                }
                cleanupOutcomeCounts[cleanup.outcome.rawValue, default: 0] += 1
                defer { cleanupCompletedCount += 1 }
                guard !Task.isCancelled, host.cleanUpTranscriptions, !host.sessionIsDeleted(session),
                      let text = cleanup.texts.first, text != phrase.text else {
                    cleanupBypassedCount += 1; continue
                }
                do {
                    let readable = PhraseCleanup.distribute(text, over: phrase.sources.map(\.text))
                    if try host.store?.setReadablePhrase(readable, for: phrase.sources) == true {
                        cleanupAppliedCount += 1
                        let texts = Dictionary(uniqueKeysWithValues: zip(phrase.sources.map(\.id), readable))
                        host.replaceLive(texts: texts)
                        host.didClean(phrase.sources, texts: texts)
                    } else { cleanupBypassedCount += 1 }
                } catch { cleanupBypassedCount += 1 }
            }
        }
    }

    /// One dictation row through the on-device cleanup, counted with the live phrases in the recovery diagnostics.
    func cleanDictation(_ text: String) async -> (text: String, outcome: CleanupResult.Outcome) {
        cleanupRequestedCount += 1
        let cleanup = await host.dependencies.cleanup(transcriptCleanup, [text], Self.dictationCleanupTimeout)
        cleanupCompletedCount += 1
        cleanupOutcomeCounts[cleanup.outcome.rawValue, default: 0] += 1
        if let first = cleanup.texts.first, first != text { cleanupAppliedCount += 1; return (first, cleanup.outcome) }
        cleanupBypassedCount += 1
        return (text, cleanup.outcome)
    }

    func cancelDictationCleanup() { transcriptCleanup.cancel() }

    /// Quitting cancels the running phrase and drops the queue; recognized text is already saved.
    func shutdown() {
        for task in cleanupTasks.values { task.cancel() }
        cleanupQueue.removeAll(); phraseCleanup = PhraseCleanup()
    }
}
