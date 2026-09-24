import Foundation
import JotCore

/// What the library needs from the service: the tuning that groups rows, whether a finished session is settled, and a place to report.
@MainActor
protocol SessionLibraryHost: AnyObject {
    var tuning: TranscriptionTuning { get }
    var notice: String { get set }
    /// The session's last audio block is recognized and its cleanup has landed, so its rows will not change under a relabel.
    func sessionIsSettled(_ id: String) -> Bool
}

/// Reads and edits saved sessions and dictations for the screens and the socket API: recent rows, the paged Dictations list, Sessions, export, rename, delete, and regroup. Capture writes rows itself and hands the saved rows and cleaned text to the Live feed here.
@MainActor
final class SessionLibrary: ObservableObject {
    var store: TranscriptStore?
    @Published var recent: [Transcript] = []
    /// The session Live shows. It is read once when shown; after that new rows and cleaned text arrive as they are saved.
    /// Not @Published: its setter would copy every row of the feed on each change. The feed changes in place after objectWillChange.
    private(set) var live = LiveFeed()
    /// True when Live's last read failed, so the next show reads again even for the session already shown.
    private var liveReadFailed = false
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
    /// Relabels waiting for their session to settle or writing.
    @Published private var relabelsInFlight = 0
    /// Relabels write here one at a time, so a pass and a Regroup of the same session cannot interleave their writes, and their blocking store work and the pauses between batches never hold a thread of Swift's cooperative pool.
    private static let relabelQueue = DispatchQueue(label: "Jot.relabel", qos: .userInitiated)
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
        reloadLive()
        historyRevision += 1
    }

    /// Folded and merged rows for reading one session. Stored rows are untouched.
    func sessionParagraphs(_ id: String) -> [Transcript] {
        guard let store else { return [] }
        let gap = host.tuning.bounded.paragraphPause
        do { return TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(try store.session(id: id), gap: gap), mergeWithin: gap) }
        catch { host.notice = error.localizedDescription; return [] }
    }

    /// Live joins rows up to phrase cleanup's 1.2-second gap even under a shorter paragraph pause, so a cleaned phrase stays one paragraph.
    private static let liveMergeGap = 1.21

    /// Shows one session in Live, reading it once. Showing the session already shown keeps it as it is, unless its last read failed.
    func showLive(_ id: String?) {
        guard id != live.sessionID || liveReadFailed else { return }
        loadLive(id)
    }

    /// Reads Live's session again after an edit that is not a new row or cleanup: a speaker name, a delete, a regroup, or a new paragraph pause.
    func reloadLive() {
        loadLive(live.sessionID)
    }

    /// Rows just saved; Live adds those of the session it shows.
    func appendLive(_ rows: [Transcript]) {
        objectWillChange.send()
        live.append(rows)
    }

    /// Cleaned text just saved, by row id; Live puts it in place of the raw text.
    func replaceLive(texts: [String: String]) {
        objectWillChange.send()
        live.replace(texts: texts)
    }

    private func loadLive(_ id: String?) {
        let gap = max(Self.liveMergeGap, host.tuning.bounded.paragraphPause)
        guard let id, let store else {
            liveReadFailed = false
            objectWillChange.send()
            live.show(sessionID: nil, rows: [], labels: [:], gap: gap)
            return
        }
        do {
            let rows = try store.session(id: id)
            let labels = try store.labels(sessionID: id)
            liveReadFailed = false
            objectWillChange.send()
            live.show(sessionID: id, rows: rows, labels: labels, gap: gap)
        } catch {
            host.notice = error.localizedDescription
            liveReadFailed = true
            // A failed reload keeps what Live shows. A failed switch still moves Live to the new session, with no rows, so rows saved from now on show.
            if id != live.sessionID {
                objectWillChange.send()
                live.show(sessionID: id, rows: [], labels: [:], gap: gap)
            }
        }
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

    /// Relabels a saved session's rows from its stored words under the current Tuning: from the speaker pass's segments when the session has them, otherwise from the live probabilities. Rows keep their cleaned text; a row whose speaker changes inside it splits there.
    func regroupSession(_ id: String, segments: [(speaker: String, start: Double, end: Double)]) async throws {
        let tuning = host.tuning
        let speakers: @Sendable ([StoredWord]) -> [String?]
        if segments.isEmpty {
            speakers = { TranscriptGrouping.speakers(words: $0, tuning: tuning) }
        } else {
            speakers = { SpeakerPassRelabel.speakers(words: $0, segments: segments, tuning: tuning) }
        }
        // Batches written before a failure stay, so Live and Sessions reload either way.
        defer { didDeleteHistory() }
        let changed = try await relabel(id, speakers: speakers)
        // Deleted while the Regroup waited its turn; the delete has said so already.
        if deletedSessions.contains(id) { return }
        guard changed else {
            throw JotError.message("This session was recorded before Jot kept word timings; it cannot be regrouped.")
        }
        host.notice = segments.isEmpty ? "Session regrouped with the current tuning." : "Session regrouped from the speaker pass."
    }

    /// A relabel is waiting or writing; Install Update waits for it.
    var isRelabeling: Bool { relabelsInFlight > 0 }

    /// Relabels one finished session's rows from one speaker per stored word. It waits until the session is settled: a row split while its phrase is still being cleaned would never get the cleaned text. Then the work and the store writes run on the relabel queue, after any relabel already there; the caller reloads the screens. False when the session has no stored words.
    func relabel(_ id: String, speakers: @escaping @Sendable ([StoredWord]) -> [String?]) async throws -> Bool {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        relabelsInFlight += 1
        defer { relabelsInFlight -= 1 }
        try await waitUntilSettled(id)
        return try await withCheckedThrowingContinuation { continuation in
            Self.relabelQueue.async {
                continuation.resume(with: Result(catching: { try store.relabelSession(id, speakers: speakers) }))
            }
        }
    }

    private func waitUntilSettled(_ id: String) async throws {
        while !host.sessionIsSettled(id) {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Deletes one Dictations card. `discard` gets the row ids it was built from before the delete, so a pending attempt over them cannot insert.
    func deleteHistoryCard(_ item: Transcript, discard: ([String]) -> Void) throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let ids = historySources[item.id] ?? [item.id]
        discard(ids)
        try store.deleteTranscripts(ids: ids)
        didDeleteHistory()
        host.notice = "Transcript deleted."
    }

    /// Deletes every saved dictation; sessions are kept. `discardAttempt` drops the live attempt once storage is known to be there.
    func clearHistory(discardAttempt: () -> Void) throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        discardAttempt()
        try store.clearHistory()
        historyClearedAt = ProcessInfo.processInfo.systemUptime
        lastExport = nil
        historyLimit = 50
        didDeleteHistory()
        host.notice = "Dictations cleared. Sessions were kept."
    }
}
