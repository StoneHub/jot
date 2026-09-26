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
    var live: LiveFeed { library.live }
    var sessions: [TranscriptSession] { library.sessions }
    var lastExport: URL? { library.lastExport }
    static var exportDirectory: URL { SessionLibrary.exportDirectory }

    func refreshRecent() { library.refreshRecent() }
    func refreshSessions() { library.refreshSessions() }
    func searchHistory(_ query: String) { library.searchHistory(query) }
    func loadMoreHistory() { library.loadMoreHistory() }
    func sessionParagraphs(_ id: String) -> [Transcript] { library.sessionParagraphs(id) }
    func showLive(_ id: String?) { library.showLive(id) }
    func appendLive(_ rows: [Transcript]) { library.appendLive(rows) }
    func replaceLive(texts: [String: String]) { library.replaceLive(texts: texts) }
    func didClean(_ sources: [Transcript], texts: [String: String]) { library.didClean(sources, texts: texts) }
    func searchSessions(_ query: String) -> [Transcript] { library.searchSessions(query) }
    func renameSession(_ id: String, title: String) { library.renameSession(id, title: title) }
    func exportable(_ id: String) throws -> (session: TranscriptSession, rows: [Transcript]) { try library.exportable(id) }
    @discardableResult func exportSession(_ id: String) throws -> URL { try library.exportSession(id) }

    func canDeleteSession(_ id: String) -> Bool { !(id == activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        try library.deleteSession(id)
    }

    func regroupSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        try await library.regroupSession(id, segments: try speakers.segments(sessionID: id))
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
        // The name is saved before the voice is remembered, so Live shows it even when remembering the voice fails.
        defer { library.reloadLive() }
        do { try speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: voice) }
        catch { notice = error.localizedDescription }
    }
    func passEmbedding(session: String, speaker: String) -> [Float]? { speakers.passEmbedding(session: session, speaker: speaker) }
    func refreshPeople() { speakers.refreshPeople() }
    func renamePerson(_ id: String, name: String) { speakers.renamePerson(id, name: name) }
    func deletePerson(_ id: String) { speakers.deletePerson(id) }

    // MARK: Listening timeline

    var sessionID: String { timeline.sessionID }
    var sessionStarted: Date { timeline.sessionStarted }
    var ambientOffset: Double { timeline.ambientOffset }
    var activeSessionID: String? { timeline.activeSessionID }

    // MARK: Dictation

    func beginDictation() { dictation.begin() }
    func endDictation() { if dictation.end() { level = 0 } }
    func cancelTapDictation() { dictation.cancelTap() }
    func recoverRecentDictation() { dictation.recoverRecent() }
}

extension SpeechService: SessionLibraryHost {
    func sessionIsSettled(_ id: String) -> Bool { jobs.allSatisfy { $0.sessionID != id } && processing == nil && !cleanup.isCleaning(session: id) }
}

extension SpeechService: ListeningTimelineHost {
    func markDictationGap(_ recoveryNotice: String) { dictation.markGap(recoveryNotice) }
    func enqueueSpeakerPass(_ file: SessionAudioFile) { speakers.enqueuePass(file) }
}

extension SpeechService: LiveCleanupHost {}

extension SpeechService: SpeakerRecognizerHost {
    func sessionIsDeleted(_ id: String) -> Bool { library.deletedSessions.contains(id) }
    func didRelabelSession() { library.didDeleteHistory() }
    func relabel(_ id: String, speakers: @escaping @Sendable ([StoredWord]) -> [String?]) async throws -> Bool { try await library.relabel(id, speakers: speakers) }
}

extension SpeechService: DictationHost {
    var shortcutName: String { shortcut.displayName }
    var canHoldDictation: Bool { lifecycle.phase == .ready && modelState == .ready && ambientEnabled && !pauseRequested }
    func closeChunk() { drainAudio(); timeline.flushAmbient(final: true) }
    func cancelDictationCleanup() { cleanup.cancelDictationCleanup() }
    func cleanDictation(_ text: String) async -> (text: String, outcome: CleanupResult.Outcome) { await cleanup.cleanDictation(text) }
}
