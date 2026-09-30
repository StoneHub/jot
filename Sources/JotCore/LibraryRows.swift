import Foundation

/// The newest rows and the Sessions list the screens show. A read takes them from the store in full; after that, the rows each recognition block saves and the cleaned text each phrase applies are folded in without reading the store again, so a block's work follows the block, not how much has been saved. Any other edit to saved rows (a delete, a regroup, a speaker name, a title) reads them in full again.
public struct LibraryRows: Sendable {
    public static let recentLimit = 20
    public static let sessionLimit = 200

    public private(set) var recent: [Transcript] = []
    public private(set) var sessions: [TranscriptSession] = []
    /// False until a read succeeds, and again after a read or a fold fails; the next fold then reads in full.
    private var recentIsCurrent = false
    private var sessionsAreCurrent = false

    public init() {}

    /// The newest rows of either kind, as `TranscriptStore.recent` returns them.
    public mutating func readRecent(from store: TranscriptStore?) throws {
        recentIsCurrent = false
        recent = try store?.recent(limit: Self.recentLimit) ?? []
        recentIsCurrent = true
    }

    /// The ambient sessions, as `TranscriptStore.sessions` returns them.
    public mutating func readSessions(from store: TranscriptStore?) throws {
        sessionsAreCurrent = false
        sessions = try store?.sessions(limit: Self.sessionLimit) ?? []
        sessionsAreCurrent = true
    }

    /// Rows a recognition block has just saved to `store`, as the block built them. Reads only the speaker names of their sessions, and the summary of a session the list does not hold yet.
    public mutating func add(_ saved: [Transcript], savedTo store: TranscriptStore) throws {
        guard !saved.isEmpty else { return }
        do {
            let rows = try Self.stored(saved, labels: store.labels(sessionID:))
            if recentIsCurrent { recent = Self.newest(rows, merging: recent, limit: Self.recentLimit) }
            else { try readRecent(from: store) }
            if sessionsAreCurrent { sessions = try Self.sessions(sessions, adding: rows, limit: Self.sessionLimit, summary: store.sessionSummary(id:)) }
            else { try readSessions(from: store) }
        } catch {
            recentIsCurrent = false; sessionsAreCurrent = false
            throw error
        }
    }

    /// Folds a committed block after an asynchronous read. Another snapshot may
    /// already include these ids, or cleanup may already have edited their text.
    /// Read only this block's rows and session summaries, then replace by identity.
    public mutating func addCommitted(_ saved: [Transcript], savedTo store: TranscriptStore) throws {
        let committed = try saved.compactMap { try store.read(id: $0.id) }
        let submittedIDs = Set(saved.map(\.id))
        if recentIsCurrent { recent = Self.newest(committed, merging: recent.filter { !submittedIDs.contains($0.id) }, limit: Self.recentLimit) }
        else { try readRecent(from: store) }
        if !sessionsAreCurrent { try readSessions(from: store); return }
        for id in Set(saved.filter { $0.mode == "ambient" }.map(\.sessionID)) {
            sessions.removeAll { $0.sessionID == id }
            if let summary = try store.sessionSummary(id: id) { sessions.append(summary) }
        }
        sessions = Array(sessions.sorted {
            if $0.lastTranscriptAt != $1.lastTranscriptAt { return $0.lastTranscriptAt > $1.lastTranscriptAt }
            return $0.sessionID.utf8.lexicographicallyPrecedes($1.sessionID.utf8)
        }.prefix(Self.sessionLimit))
    }

    /// Cleaned text a phrase has just saved, by row id. The rows keep their places; Sessions holds no text.
    public mutating func replace(texts: [String: String]) {
        recent = Self.replacing(texts, in: recent)
    }

    /// Rows as the store reads them back: named from their session's speaker names, and dated by the seconds the store keeps.
    public static func stored(_ rows: [Transcript], labels: (String) throws -> [String: String]) rethrows -> [Transcript] {
        var names: [String: [String: String]] = [:]
        for session in Set(rows.filter { $0.speakerID != nil }.map(\.sessionID)) { names[session] = try labels(session) }
        return rows.map { row in
            var stored = row
            stored.startedAt = Date(timeIntervalSince1970: row.startedAt.timeIntervalSince1970)
            stored.speakerLabel = row.speakerID.flatMap { names[row.sessionID]?[$0] }
            return stored
        }
    }

    /// The newest `limit` of `rows` (already newest first) and `saved`, in the store's order: absolute start, then id, both descending.
    public static func newest(_ saved: [Transcript], merging rows: [Transcript], limit: Int) -> [Transcript] {
        let replaced = Set(saved.map(\.id))
        return Array((rows.filter { !replaced.contains($0.id) } + saved).sorted(by: isNewer).prefix(limit))
    }

    /// The store's row order: `(started_at + start_seconds) DESC, id DESC`, ids compared bytewise as SQLite does.
    public static func isNewer(_ a: Transcript, than b: Transcript) -> Bool {
        let first = a.startedAt.timeIntervalSince1970 + a.startSeconds, second = b.startedAt.timeIntervalSince1970 + b.startSeconds
        if first != second { return first > second }
        return b.id.utf8.lexicographicallyPrecedes(a.id.utf8)
    }

    public static func replacing(_ texts: [String: String], in rows: [Transcript]) -> [Transcript] {
        guard !texts.isEmpty else { return rows }
        return rows.map { row in
            guard let text = texts[row.id] else { return row }
            var cleaned = row; cleaned.text = text; return cleaned
        }
    }

    /// `sessions` with the ambient rows of `saved` counted in, in the store's order: latest row end, then session id. A session the list does not hold is read with `summary`, which already counts the saved rows.
    public static func sessions(_ sessions: [TranscriptSession], adding saved: [Transcript], limit: Int,
                                summary: (String) throws -> TranscriptSession?) rethrows -> [TranscriptSession] {
        let ambient = saved.filter { $0.mode == "ambient" }
        guard !ambient.isEmpty else { return sessions }
        var result = sessions
        for (id, rows) in Dictionary(grouping: ambient, by: \.sessionID) {
            if let index = result.firstIndex(where: { $0.sessionID == id }) {
                let held = result[index]
                let starts = rows.map(\.startedAt.timeIntervalSince1970), ends = rows.map { $0.startedAt.timeIntervalSince1970 + $0.endSeconds }
                result[index] = TranscriptSession(sessionID: id,
                    startedAt: min(held.startedAt, Date(timeIntervalSince1970: starts.min()!)),
                    lastTranscriptAt: max(held.lastTranscriptAt, Date(timeIntervalSince1970: ends.max()!)),
                    transcriptCount: held.transcriptCount + rows.count, title: held.title)
            } else if let read = try summary(id) {
                result.append(read)
            }
        }
        return Array(result.sorted { a, b in
            if a.lastTranscriptAt != b.lastTranscriptAt { return a.lastTranscriptAt > b.lastTranscriptAt }
            return a.sessionID.utf8.lexicographicallyPrecedes(b.sessionID.utf8)
        }.prefix(limit))
    }
}
