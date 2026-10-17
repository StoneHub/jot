import Foundation
import JotCore
import JotEngine

/// Deleting, regrouping and naming saved sessions and History cards, handed to the library and speakers.
/// A session still being recorded cannot be deleted or regrouped.
extension SpeechService {
    /// The session being recorded belongs to Live until capture stops.
    func canDeleteSession(_ id: String) -> Bool { !(id == timeline.activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        try await library.deleteSession(id)
        await speakers.deleteTuningAudio(session: id)
    }

    func regroupSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        try await library.regroupSession(id) { try await speakers.segments(sessionID: id) }
        speakers.didRegroup(id)
    }

    func deleteHistoryCard(_ item: Transcript) async throws {
        try await library.deleteHistoryCard(item, discard: dictation.discard(ids:))
    }

    func clearHistory() async throws {
        try await library.clearHistory(discardAttempt: dictation.discardForHistoryReset)
    }

    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]? = nil) async {
        // The name is saved before the voice is remembered, so Live shows it even when remembering the voice fails.
        defer { library.reloadLive() }
        do { try await speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: voice) }
        catch { notice = error.localizedDescription }
    }

    /// The session's last audio block is recognized and its cleanup has landed, so its rows will not change under a relabel.
    func sessionIsSettled(_ id: String) -> Bool { transcriber.isDone(session: id) && !cleanup.isCleaning(session: id) }
}
