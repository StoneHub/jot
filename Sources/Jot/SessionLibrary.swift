import Foundation
import JotCore

/// What the library needs from the service: the tuning that groups rows, and a place to report.
@MainActor
protocol SessionLibraryHost: AnyObject {
    var tuning: TranscriptionTuning { get }
    var notice: String { get set }
}

/// Reads and edits saved sessions and dictations for the screens and the socket API: recent rows, the paged Dictations list, Sessions, export, rename, delete, and regroup. Live capture never goes through here.
@MainActor
final class SessionLibrary: ObservableObject {
    var store: TranscriptStore?
    @Published var recent: [Transcript] = []
    /// Content changes include cleanup replacements that leave row counts unchanged.
    @Published private(set) var transcriptRevision = 0
    @Published var history: [Transcript] = []
    @Published var events: [CaptureEvent] = []
    @Published var hasMoreHistory = false
    /// Every saved dictation row, for the Dictations count in the sidebar.
    @Published private(set) var dictationCount = 0
    @Published private(set) var historyRevision = 0
    @Published private(set) var sessions: [TranscriptSession] = []
    @Published private(set) var lastExport: URL?
    private var historySources: [String: [String]] = [:]
    /// Uptime of the last Clear; recognition jobs submitted before it must not append to the cleared list.
    private(set) var historyClearedAt: TimeInterval = -1
    private(set) var deletedSessions = Set<String>()
    private var historyQuery = ""
    private var historyLimit = 50
    private unowned let host: SessionLibraryHost

    init(host: SessionLibraryHost) { self.host = host }

    static var exportDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jot Sessions", isDirectory: true)
    }

    func refreshRecent() {
        do {
            recent = try store?.recent(limit: 20) ?? []
            events = try store?.events(limit: 50) ?? []
            refreshHistory()
            transcriptRevision += 1
        }
        catch { host.notice = error.localizedDescription }
    }

    func refreshEvents() {
        do { events = try store?.events(limit: 50) ?? [] } catch { host.notice = "Could not save capture event: \(error.localizedDescription)" }
    }

    func refreshSessions() {
        do { sessions = try store?.sessions(limit: 200) ?? [] } catch { host.notice = error.localizedDescription }
    }

    func searchHistory(_ query: String) { historyQuery = query; historyLimit = 50; refreshHistory() }
    func loadMoreHistory() { historyLimit += 50; refreshHistory() }

    func refreshHistory() {
        do {
            // Store limits each request to 200; page so the UI can browse its whole history.
            var found: [Transcript] = []
            while found.count < historyLimit + 1 {
                let count = min(200, historyLimit + 1 - found.count)
                // History is the dictation list; ambient rows are read from Sessions.
                let page = try historyQuery.isEmpty ? store?.recent(mode: "dictation", limit: count, offset: found.count) : store?.search(historyQuery, mode: "dictation", limit: count, offset: found.count)
                let items = page ?? []; found.append(contentsOf: items)
                if items.count < count { break }
            }
            hasMoreHistory = found.count > historyLimit
            dictationCount = try store?.count(mode: "dictation") ?? 0
            let groups = TranscriptGrouping.historyGroups(Array(found.prefix(historyLimit)), tuning: host.tuning)
            history = groups.map(\.transcript)
            historySources = Dictionary(uniqueKeysWithValues: groups.map { ($0.transcript.id, $0.sourceIDs) })
        } catch { host.notice = error.localizedDescription }
    }

    func didDeleteHistory() {
        refreshRecent(); refreshSessions()
        historyRevision += 1
    }

    /// Folded and merged rows for reading one session. Stored rows are untouched.
    func sessionParagraphs(_ id: String, minimumMergeGap: Double = 0) -> [Transcript] {
        guard let store else { return [] }
        let gap = max(minimumMergeGap, host.tuning.bounded.paragraphPause)
        do { return TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(try store.session(id: id), gap: gap), mergeWithin: gap) }
        catch { host.notice = error.localizedDescription; return [] }
    }

    /// Rows from any ambient session whose text contains the query, newest first, for the Sessions search.
    func searchSessions(_ query: String) -> [Transcript] {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do { return try store.search(query, mode: "ambient", limit: 50) } catch { host.notice = error.localizedDescription; return [] }
    }

    func renameSession(_ id: String, title: String) {
        do { try store?.setTitle(sessionID: id, title: title); refreshSessions() }
        catch { host.notice = error.localizedDescription }
    }

    /// The summary and rows an export is built from; an unknown or dictation-only id has neither.
    func exportable(_ id: String) throws -> (session: TranscriptSession, rows: [Transcript]) {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let rows = try store.session(id: id)
        guard !rows.isEmpty, let session = try store.sessionSummary(id: id) else {
            throw JotError.message("Nothing was transcribed in this session, so there is no file to save.")
        }
        return (session, rows)
    }

    /// Writes one session as Markdown into ~/Documents/Jot Sessions and returns the file.
    @discardableResult
    func exportSession(_ id: String) throws -> URL {
        let (session, rows) = try exportable(id)
        let url = try TranscriptExport.write(session: session, rows: rows, directory: Self.exportDirectory)
        lastExport = url
        return url
    }

    func clearLastExport() { lastExport = nil }

    /// The caller has already checked that the session is not recording.
    func deleteSession(_ id: String) throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        try store.deleteSession(id: id)
        deletedSessions.insert(id)
        didDeleteHistory()
        host.notice = "Session deleted."
    }

    /// Rebuilds a saved session's rows from its stored words under the current Tuning: from the speaker pass's segments when the session has them, otherwise from the live probabilities. Cleanup text is not re-run.
    func regroupSession(_ id: String, segments: [(speaker: String, start: Double, end: Double)]) throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let words = try store.words(sessionID: id)
        if segments.isEmpty {
            try store.replaceSession(sessionID: id, words: words, turns: TranscriptGrouping.regroup(words: words, tuning: host.tuning))
            host.notice = "Session regrouped with the current tuning."
        } else {
            try store.replaceSession(sessionID: id, words: words, turns: SpeakerPassRelabel.turns(words: words, segments: segments, tuning: host.tuning))
            host.notice = "Session regrouped from the speaker pass."
        }
        didDeleteHistory()
    }

    /// Deletes one Dictations card and returns the row ids it was built from, so a pending attempt over them can be discarded.
    func deleteHistoryCard(_ item: Transcript) throws -> [String] {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let ids = historySources[item.id] ?? [item.id]
        try store.deleteTranscripts(ids: ids)
        didDeleteHistory()
        host.notice = "Transcript deleted."
        return ids
    }

    /// Deletes every saved dictation; sessions are kept. The caller discards the live attempt first.
    func clearHistory() throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        try store.clearHistory()
        historyClearedAt = ProcessInfo.processInfo.systemUptime
        lastExport = nil
        historyLimit = 50
        didDeleteHistory()
        host.notice = "Dictations cleared. Sessions were kept."
    }
}
