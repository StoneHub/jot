import Foundation
import JotCore

/// The service keeps the members the screens and the socket API bind to; the work behind them lives in the objects it owns.
extension SpeechService {
    // MARK: Capture

    var inputDevices: [AudioInputDevice] { capture.inputDevices }
    var selectedInputUID: String { capture.selectedInputUID }
    var selectedInputName: String { capture.selectedInputName }
    var selectedInputMissing: Bool { capture.selectedInputMissing }
    var systemDefaultInputName: String { capture.systemDefaultInputName }
    var inputRows: [AudioInputDevice] { capture.inputRows }
    func refreshInputDevices() { capture.refreshInputDevices() }

    func setInput(uid: String) {
        guard canChangeInput else { return }
        do { try capture.setInput(uid: uid); notice = "" }
        catch { notice = error.localizedDescription }
    }

    // MARK: Sessions and dictations on disk

    var store: TranscriptStore? {
        get { library.store }
        set { library.store = newValue }
    }
    var recent: [Transcript] { library.recent }
    var history: [Transcript] { library.history }
    var events: [CaptureEvent] { library.events }
    var hasMoreHistory: Bool { library.hasMoreHistory }
    var dictationCount: Int { library.dictationCount }
    var historyRevision: Int { library.historyRevision }
    var transcriptRevision: Int { library.transcriptRevision }
    var sessions: [TranscriptSession] { library.sessions }
    var lastExport: URL? { library.lastExport }
    static var exportDirectory: URL { SessionLibrary.exportDirectory }

    func refreshRecent() { library.refreshRecent() }
    func refreshSessions() { library.refreshSessions() }
    func searchHistory(_ query: String) { library.searchHistory(query) }
    func loadMoreHistory() { library.loadMoreHistory() }
    func sessionParagraphs(_ id: String, minimumMergeGap: Double = 0) -> [Transcript] { library.sessionParagraphs(id, minimumMergeGap: minimumMergeGap) }
    func searchSessions(_ query: String) -> [Transcript] { library.searchSessions(query) }
    func renameSession(_ id: String, title: String) { library.renameSession(id, title: title) }
    func exportable(_ id: String) throws -> (session: TranscriptSession, rows: [Transcript]) { try library.exportable(id) }
    @discardableResult func exportSession(_ id: String) throws -> URL { try library.exportSession(id) }

    func canDeleteSession(_ id: String) -> Bool { !(id == activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        try library.deleteSession(id)
    }

    func regroupSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        try library.regroupSession(id, segments: try speakers.segments(sessionID: id))
    }

    func deleteHistoryCard(_ item: Transcript) throws {
        try library.deleteHistoryCard(item, discard: dictation.discard(ids:))
    }

    func clearHistory() throws {
        try library.clearHistory(discardAttempt: dictation.discardForHistoryReset)
    }

    // MARK: Speakers and people

    var speakerStore: SpeakerPassStore? {
        get { speakers.speakerStore }
        set { speakers.speakerStore = newValue }
    }
    var peopleStore: PeopleStore? {
        get { speakers.peopleStore }
        set { speakers.peopleStore = newValue }
    }
    var people: [Person] { speakers.people }
    var speakerPassRunning: Bool { speakers.passRunning }

    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]? = nil) {
        do { try speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: voice) }
        catch { notice = error.localizedDescription }
    }
    func passEmbedding(session: String, speaker: String) -> [Float]? { speakers.passEmbedding(session: session, speaker: speaker) }
    func refreshPeople() { speakers.refreshPeople() }
    func renamePerson(_ id: String, name: String) { speakers.renamePerson(id, name: name) }
    func deletePerson(_ id: String) { speakers.deletePerson(id) }

    // MARK: Dictation

    func beginDictation() { dictation.begin() }
    func endDictation() { if dictation.end() { level = 0 } }
    func cancelTapDictation() { dictation.cancelTap() }
    func recoverRecentDictation() { dictation.recoverRecent() }
}

extension SpeechService: SessionLibraryHost {}

extension SpeechService: SpeakerRecognizerHost {
    func sessionIsDeleted(_ id: String) -> Bool { library.deletedSessions.contains(id) }
    func recognitionIsComplete(for session: String) -> Bool { jobs.allSatisfy { $0.sessionID != session } && processing == nil }
    func didRelabelSession() { library.didDeleteHistory() }
}

extension SpeechService: DictationHost {
    var shortcutName: String { shortcut.displayName }
    var canHoldDictation: Bool { lifecycle.phase == .ready && modelState == .ready && ambientEnabled && !pauseRequested }
    func closeChunk() { drainAudio(); flushAmbient(final: true) }
    func cancelDictationCleanup() { transcriptCleanup.cancel() }

    /// One dictation row through the on-device cleanup, counted with the live phrases in the recovery diagnostics.
    func cleanDictation(_ text: String) async -> String {
        cleanupRequestedCount += 1
        let cleanup = await dependencies.cleanup(transcriptCleanup, [text], Self.dictationCleanupTimeout)
        cleanupCompletedCount += 1
        cleanupOutcomeCounts[cleanup.outcome.rawValue, default: 0] += 1
        if let first = cleanup.texts.first, first != text { cleanupAppliedCount += 1; return first }
        cleanupBypassedCount += 1
        return text
    }
}
