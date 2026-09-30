import Foundation
import JotCore

/// Reads and edits saved sessions and dictations for the screens and the socket API: recent rows, the paged Dictations list, Sessions, export, rename, delete, and regroup. Capture writes rows itself and hands the saved rows and cleaned text here, to Live, the recent rows, Sessions and Dictations.
@MainActor
final class SessionLibrary: ObservableObject {
    var store: TranscriptStore? {
        didSet { contentRevision &+= 1 }
    }
    /// Recent rows and Sessions: read in full on an edit, and kept current from each recognition block's saved rows.
    @Published private var rows = LibraryRows()
    var recent: [Transcript] { rows.recent }
    var sessions: [TranscriptSession] { rows.sessions }
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
    @Published private(set) var lastExport: URL?
    private var historySources: [String: [String]] = [:]
    /// The rows Dictations was built from, newest first, one past the page so it knows there is more.
    private var historyRows: [Transcript] = []
    /// False until the Dictations read succeeds, and after one fails; the next block then reads the list in full.
    private var historyIsCurrent = false
    private(set) var deletedSessions = Set<String>()
    /// A delete is submitted before its SQL work starts. Writers wait for its result:
    /// success closes the session, while failure leaves its saved rows writable.
    private var pendingDeletions: [String: StoreOperation<Void>] = [:]
    var pendingDeletionCount: Int { pendingDeletions.count }
    /// Relabels waiting for their session to settle or writing. Install Update reads this through the service, so a change redraws the screens that observe the service; it changes when a relabel starts and ends.
    private var relabelsInFlight = 0 {
        willSet { if (relabelsInFlight == 0) != (newValue == 0) { service.objectWillChange.send() } }
    }
    private var historyQuery = ""
    private var historyLimit = 50
    private var titleRequests: [String: UInt64] = [:]
    private unowned let service: SpeechService
    /// Reads and writes share submission order, including capture and session edits.
    let storeExecutor: StoreExecutor
    private var readTask: Task<Void, Never>?
    private var readSequence = 0
    private var contentRevision = 0
    private var historyRequest = 0
    private var liveRequest = 0
    private var pendingLiveID: String?
    private var recentReadQueued = false
    private var recentReadNeedsRefresh = false
    private var sessionsReadQueued = false
    private var sessionsReadNeedsRefresh = false
    private let isSessionSettled: (String) -> Bool
    private let isApplyingPass: (String) -> Bool

    init(service: SpeechService, executor: StoreExecutor, isSessionSettled: @escaping (String) -> Bool,
         isApplyingPass: @escaping (String) -> Bool) {
        self.service = service
        self.storeExecutor = executor
        self.isSessionSettled = isSessionSettled
        self.isApplyingPass = isApplyingPass
    }

    private func enqueueRead(_ work: @escaping @MainActor () async -> Void) {
        let previous = readTask
        readSequence &+= 1
        let sequence = readSequence
        // An in-flight read can outlive its caller's last reference to the service.
        // Its work still accesses `service` through this library's unowned link, so
        // retain the owner only until this queued read has finished. The final task
        // clears readTask below, breaking the temporary owner/library/task cycle.
        let owner = service
        readTask = Task { [weak self, owner] in
            await previous?.value
            guard let self else { withExtendedLifetime(owner) {}; return }
            await work()
            if sequence == self.readSequence { self.readTask = nil }
            withExtendedLifetime(owner) {}
        }
    }

    /// Waits for screen reads requested so far, including follow-up reads scheduled after a stale snapshot.
    func waitForReads() async {
        while let task = readTask {
            let sequence = readSequence
            await task.value
            if sequence == readSequence { return }
        }
    }

    /// A deleted session's late recognition, cleanup and speaker pass must not write rows back.
    func sessionIsDeleted(_ id: String) -> Bool { deletedSessions.contains(id) }

    /// True only if deletion committed. A failed delete must not silently drop a
    /// recognition block or speaker result that still belongs to the session.
    func waitForDeletion(_ id: String) async -> Bool {
        if deletedSessions.contains(id) { return true }
        guard let operation = pendingDeletions[id] else { return false }
        do { try await operation.value; return true }
        catch { return false }
    }

    static var exportDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jot Sessions", isDirectory: true)
    }

    func refreshRecent() {
        guard !recentReadQueued else { recentReadNeedsRefresh = true; return }
        recentReadQueued = true
        let store = store
        let revision = contentRevision
        enqueueRead { [weak self] in
            guard let self else { return }
            defer {
                recentReadQueued = false
                if recentReadNeedsRefresh { recentReadNeedsRefresh = false; refreshRecent() }
            }
            guard revision == contentRevision else { recentReadNeedsRefresh = true; return }
            let baseline = rows
            do {
                let result = try await storeExecutor.perform {
                    var next = baseline
                    try next.readRecent(from: store)
                    return (next, try store?.events(limit: 50) ?? [])
                }
                guard revision == contentRevision else { recentReadNeedsRefresh = true; return }
                rows = result.0
                events = result.1
                refreshHistory()
            } catch {
                if revision == contentRevision { service.notice = error.localizedDescription }
                else { recentReadNeedsRefresh = true }
            }
        }
    }

    func refreshEvents() {
        let store = store
        enqueueRead { [weak self] in
            guard let self else { return }
            do { events = try await storeExecutor.perform { try store?.events(limit: 50) ?? [] } }
            catch { service.notice = "Could not save capture event: \(error.localizedDescription)" }
        }
    }

    func refreshSessions() {
        guard !sessionsReadQueued else { sessionsReadNeedsRefresh = true; return }
        sessionsReadQueued = true
        let store = store
        let revision = contentRevision
        enqueueRead { [weak self] in
            guard let self else { return }
            defer {
                sessionsReadQueued = false
                if sessionsReadNeedsRefresh { sessionsReadNeedsRefresh = false; refreshSessions() }
            }
            guard revision == contentRevision else { sessionsReadNeedsRefresh = true; return }
            let baseline = rows
            do {
                let next = try await storeExecutor.perform {
                    var next = baseline
                    try next.readSessions(from: store)
                    return next
                }
                guard revision == contentRevision else { sessionsReadNeedsRefresh = true; return }
                rows = next
            } catch {
                if revision == contentRevision { service.notice = error.localizedDescription }
                else { sessionsReadNeedsRefresh = true }
            }
        }
    }

    /// Rows a recognition block has just saved. Recent rows, Sessions and Dictations take them in without reading the whole store, so a block's work does not grow with the history.
    func didSave(_ saved: [Transcript]) {
        guard let store, !saved.isEmpty else { return }
        contentRevision &+= 1
        enqueueRead { [weak self] in
            guard let self else { return }
            let revision = contentRevision
            let baseline = rows
            let sources = saved.filter { !self.deletedSessions.contains($0.sessionID) }
            do {
                let next = try await storeExecutor.perform {
                    var next = baseline
                    try next.addCommitted(sources, savedTo: store)
                    return next
                }
                guard revision == contentRevision else { refreshRecent(); refreshSessions(); return }
                rows = next
                if saved.contains(where: { $0.mode == "dictation" }) || !historyIsCurrent { refreshHistory() }
            } catch { service.notice = error.localizedDescription }
        }
    }

    /// Cleaned text a phrase has just saved, by row id, for the rows it replaced. Only the text of rows already listed changes, so nothing is read again, except a searched Dictations list, whose matches the text decides.
    func didClean(_ sources: [Transcript], texts: [String: String]) {
        contentRevision &+= 1
        rows.replace(texts: texts)
        guard sources.contains(where: { $0.mode == "dictation" }) else { return }
        guard historyQuery.isEmpty, historyIsCurrent else { refreshHistory(); return }
        showHistory(LibraryRows.replacing(texts, in: historyRows), count: dictationCount)
    }

    func searchHistory(_ query: String) { historyQuery = query; historyLimit = 50; refreshHistory() }
    func loadMoreHistory() { historyLimit += 50; refreshHistory() }

    func refreshHistory() {
        historyIsCurrent = false
        historyRequest &+= 1
        let request = historyRequest
        let revision = contentRevision
        let query = historyQuery
        let limit = historyLimit
        let store = store
        enqueueRead { [weak self] in
            guard let self else { return }
            guard request == historyRequest else { return }
            guard revision == contentRevision else { refreshHistory(); return }
            do {
                let result = try await storeExecutor.perform {
                    // The store limits each page to 200; keep the whole query off the main actor.
                    var found: [Transcript] = []
                    while found.count < limit + 1 {
                        let count = min(200, limit + 1 - found.count)
                        let page = try query.isEmpty
                            ? store?.recent(mode: "dictation", limit: count, offset: found.count)
                            : store?.search(query, mode: "dictation", limit: count, offset: found.count)
                        let items = page ?? []
                        found.append(contentsOf: items)
                        if items.count < count { break }
                    }
                    return (found, try store?.count(mode: "dictation") ?? 0)
                }
                guard request == historyRequest else { return }
                guard revision == contentRevision else { refreshHistory(); return }
                showHistory(result.0, count: result.1)
                historyIsCurrent = true
            } catch {
                if request == historyRequest {
                    if revision == contentRevision { service.notice = error.localizedDescription }
                    else { refreshHistory() }
                }
            }
        }
    }

    private func showHistory(_ found: [Transcript], count: Int) {
        historyRows = found
        hasMoreHistory = found.count > historyLimit
        dictationCount = count
        let groups = TranscriptGrouping.historyGroups(Array(found.prefix(historyLimit)), tuning: service.tuning)
        history = groups.map(\.transcript)
        historySources = Dictionary(uniqueKeysWithValues: groups.map { ($0.transcript.id, $0.sourceIDs) })
    }

    func didDeleteHistory() {
        contentRevision &+= 1
        refreshRecent(); refreshSessions()
        reloadLive()
        historyRevision += 1
    }

    /// Folded and merged rows for reading one session. Stored rows are untouched.
    func sessionParagraphs(_ id: String) async -> [Transcript] {
        guard let store else { return [] }
        let tuning = service.tuning
        do { return try await storeExecutor.perform { TranscriptExport.readingParagraphs(try store.session(id: id), tuning: tuning) } }
        catch { if !Task.isCancelled { service.notice = error.localizedDescription }; return [] }
    }

    /// Live joins rows up to phrase cleanup's 1.2-second gap even under a shorter paragraph pause, so a cleaned phrase stays one paragraph.
    private static let liveMergeGap = 1.21

    /// Shows one session in Live, reading it once. Showing the session already shown keeps it as it is, unless its last read failed.
    func showLive(_ id: String?) {
        if pendingLiveID == id, pendingLiveID != nil { return }
        guard id != live.sessionID || liveReadFailed || pendingLiveID != nil else { return }
        loadLive(id)
    }

    /// Reads Live's session again after an edit that is not a new row or cleanup: a speaker name, a delete, a regroup, or a new paragraph pause.
    func reloadLive() {
        loadLive(pendingLiveID ?? live.sessionID)
    }

    /// Rows just saved; Live adds those of the session it shows.
    func appendLive(_ rows: [Transcript]) {
        contentRevision &+= 1
        objectWillChange.send()
        live.append(rows)
    }

    /// Cleaned text just saved, by row id; Live puts it in place of the raw text.
    func replaceLive(texts: [String: String]) {
        contentRevision &+= 1
        objectWillChange.send()
        live.replace(texts: texts)
    }

    private func loadLive(_ id: String?) {
        let gap = max(Self.liveMergeGap, service.tuning.bounded.paragraphPause)
        liveRequest &+= 1
        let request = liveRequest
        let revision = contentRevision
        pendingLiveID = id
        guard let id, let store else {
            pendingLiveID = nil
            liveReadFailed = false
            objectWillChange.send()
            live.show(sessionID: nil, rows: [], labels: [:], gap: gap)
            return
        }
        enqueueRead { [weak self] in
            guard let self else { return }
            guard request == liveRequest else { return }
            if revision != contentRevision { loadLive(id); return }
            let baseline = live
            do {
                let snapshot = try await storeExecutor.perform {
                    var next = baseline
                    next.show(sessionID: id, rows: try store.session(id: id),
                              labels: try store.labels(sessionID: id), gap: gap)
                    return next
                }
                guard request == liveRequest else { return }
                if revision != contentRevision { loadLive(id); return }
                pendingLiveID = nil
                liveReadFailed = false
                objectWillChange.send()
                live = snapshot
            } catch {
                guard request == liveRequest else { return }
                if revision != contentRevision { loadLive(id); return }
                pendingLiveID = nil
                service.notice = error.localizedDescription
                liveReadFailed = true
                // A failed reload keeps the current feed; a failed switch still follows the requested session.
                if id != live.sessionID {
                    objectWillChange.send()
                    live.show(sessionID: id, rows: [], labels: [:], gap: gap)
                }
            }
        }
    }

    /// Rows from any ambient session whose text contains the query, newest first, for the Sessions search.
    func searchSessions(_ query: String) async -> [Transcript] {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do { return try await storeExecutor.perform { try store.search(query, mode: "ambient", limit: 50) } }
        catch { if !Task.isCancelled { service.notice = error.localizedDescription }; return [] }
    }

    func renameSession(_ id: String, title: String) {
        guard !deletedSessions.contains(id) else { return }
        let request = (titleRequests[id] ?? 0) &+ 1
        titleRequests[id] = request
        if pendingDeletions[id] != nil {
            let owner = service
            Task { [weak self] in
                defer { withExtendedLifetime(owner) {} }
                guard let self, !(await waitForDeletion(id)), titleRequests[id] == request else { return }
                submitRename(id, title: title)
            }
            return
        }
        submitRename(id, title: title)
    }

    private func submitRename(_ id: String, title: String) {
        let store = store
        let write = storeExecutor.submit { try store?.setTitle(sessionID: id, title: title) }
        enqueueRead { [weak self] in
            guard let self else { return }
            do { _ = try await write.value; contentRevision &+= 1; refreshSessions() }
            catch { service.notice = error.localizedDescription }
        }
    }

    /// The summary and rows an export is built from; an unknown or dictation-only id has neither.
    func exportable(_ id: String) async throws -> (session: TranscriptSession, rows: [Transcript]) {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        return try await storeExecutor.perform {
            let rows = try store.session(id: id)
            guard !rows.isEmpty, let session = try store.sessionSummary(id: id) else {
                throw JotError.message("Nothing was transcribed in this session, so there is no file to save.")
            }
            return (session, rows)
        }
    }

    /// Writes one session as Markdown into ~/Documents/Jot Sessions and returns the file.
    @discardableResult
    func exportSession(_ id: String) async throws -> URL {
        let (session, rows) = try await exportable(id)
        let directory = Self.exportDirectory
        let tuning = service.tuning
        let url = try await storeExecutor.perform {
            try TranscriptExport.write(session: session, rows: rows, directory: directory, tuning: tuning)
        }
        lastExport = url
        return url
    }

    func clearLastExport() { lastExport = nil }

    /// The caller has already checked that the session is not recording.
    func deleteSession(_ id: String) async throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        if deletedSessions.contains(id) { return }
        if let operation = pendingDeletions[id] {
            try await operation.value
            return
        }
        let operation = storeExecutor.submit { try store.deleteSession(id: id) }
        pendingDeletions[id] = operation
        contentRevision &+= 1
        do { try await operation.value }
        catch {
            pendingDeletions.removeValue(forKey: id)
            contentRevision &+= 1
            refreshRecent(); refreshSessions(); reloadLive()
            throw error
        }
        deletedSessions.insert(id)
        pendingDeletions.removeValue(forKey: id)
        didDeleteHistory()
        service.notice = "Session deleted."
    }

    /// Relabels a saved session's rows from its stored words under the current Tuning: from the speaker pass's segments when the session has them, otherwise from the live probabilities. Rows keep their cleaned text; a row whose speaker changes inside it splits there. `segments` is read once the session has settled, so a pass that stores its segments while Regroup waits is used rather than overwritten with the live speakers. Regroup also waits while a pass is being applied to the session, so the pass moves the session's names before Regroup writes its speakers.
    func regroupSession(_ id: String, segments: () async throws -> [(speaker: String, start: Double, end: Double)]) async throws {
        let tuning = service.tuning
        var fromPass = false
        // Batches written before a failure stay, so Live and Sessions reload either way.
        defer { didDeleteHistory() }
        let changed = try await relabel(id, afterPass: true, makeSpeakers: {
            let segments = try await segments()
            fromPass = !segments.isEmpty
            if segments.isEmpty { return { TranscriptGrouping.speakers(words: $0, tuning: tuning) } }
            return { SpeakerPassRelabel.speakers(words: $0, segments: segments, tuning: tuning) }
        })
        // Deleted while the Regroup waited its turn; the delete has said so already.
        if await waitForDeletion(id) { return }
        guard changed else {
            throw JotError.message("This session was recorded before Jot kept word timings; it cannot be regrouped.")
        }
        service.notice = fromPass ? "Session regrouped from the speaker pass." : "Session regrouped with the current tuning."
    }

    /// A relabel is waiting or writing; Install Update waits for it.
    var isRelabeling: Bool { relabelsInFlight > 0 }

    /// Relabels one finished session's rows from one speaker per stored word. It waits until the session is settled: a row split while its phrase is still being cleaned would never get the cleaned text. Then the work and the store writes run on the shared store queue, after earlier edits; the caller reloads the screens. False when the session has no stored words.
    func relabel(_ id: String, speakers: @escaping @Sendable ([StoredWord]) -> [String?]) async throws -> Bool {
        try await relabel(id, makeSpeakers: { speakers })
    }

    /// The same relabel, with its speakers made once the session has settled, just before the work joins the store queue: what `makeSpeakers` reads then is what a pass stored while this waited, and later relabels write after this one. With `afterPass`, it also waits while a speaker pass is being applied to the session, so it never writes the pass's speakers ahead of the pass, which moves the session's names as it writes them.
    func relabel(_ id: String, afterPass: Bool = false, makeSpeakers: () async throws -> @Sendable ([StoredWord]) -> [String?]) async throws -> Bool {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        relabelsInFlight += 1
        defer { relabelsInFlight -= 1 }
        try await waitUntilSettled(id, afterPass: afterPass)
        guard !(await waitForDeletion(id)) else { return false }
        let speakers = try await makeSpeakers()
        guard !(await waitForDeletion(id)) else { return false }
        let changed = try await storeExecutor.submit { try store.relabelSession(id, speakers: speakers) }.value
        guard !(await waitForDeletion(id)) else { return false }
        return changed
    }

    private func waitUntilSettled(_ id: String, afterPass: Bool) async throws {
        while !isSessionSettled(id) || (afterPass && isApplyingPass(id)) {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Deletes one Dictations card. `discard` gets the row ids it was built from before the delete, so a pending attempt over them cannot insert.
    func deleteHistoryCard(_ item: Transcript, discard: ([String]) -> Void) async throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let ids = historySources[item.id] ?? [item.id]
        discard(ids)
        contentRevision &+= 1
        try await storeExecutor.submit { try store.deleteTranscripts(ids: ids) }.value
        didDeleteHistory()
        service.notice = "Transcript deleted."
    }

    /// Deletes every saved dictation; sessions are kept. `discardAttempt` drops the live attempt once storage is known to be there.
    func clearHistory(discardAttempt: () -> Void) async throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        discardAttempt()
        contentRevision &+= 1
        try await storeExecutor.submit { try store.clearHistory() }.value
        lastExport = nil
        historyLimit = 50
        didDeleteHistory()
        service.notice = "Dictations cleared. Sessions were kept."
    }
}
