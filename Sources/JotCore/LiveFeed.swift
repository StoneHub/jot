import Foundation

/// The paragraphs Live shows for one session. It reads the session once, then takes rows and cleaned text as they are saved, and regroups only from the paragraph a change touches. Grouping follows the same rules as Sessions and export: TranscriptGrouping.foldContinuation, then TranscriptExport.canMerge and merge.
public struct LiveFeed: Sendable {
    /// The session shown; nil shows nothing.
    public private(set) var sessionID: String?
    /// The session's rows folded and merged for reading, oldest first.
    public private(set) var paragraphs: [Transcript] = []
    /// Goes up with every change, so the screen knows to copy the paragraphs.
    public private(set) var revision = 0
    /// Goes up when cleaned text replaces raw text, so the screen can mark the replacement.
    public private(set) var cleanupRevision = 0
    /// The session's saved rows in spoken order, with speaker names applied.
    private var rows: [Transcript] = []
    /// Each row after the continuation rule, one for one with rows.
    private var folded: [Transcript] = []
    /// Where each paragraph starts in rows.
    private var paragraphStarts: [Int] = []
    /// Speaker names by speaker id, put on every row the way the store joins them.
    private var labels: [String: String] = [:]
    private var gap = 1.5

    public init() {}

    /// Shows one session from a full read: its rows and speaker names, grouped with this paragraph gap.
    public mutating func show(sessionID: String?, rows: [Transcript], labels: [String: String], gap: Double) {
        self.sessionID = sessionID
        self.labels = labels
        self.gap = gap
        self.rows = rows.map(labeled).sorted(by: Self.spokenBefore)
        folded = []
        paragraphs = []
        paragraphStarts = []
        regroup(from: 0)
    }

    /// Adds rows just saved, each at its spoken time. Rows of another session are ignored.
    public mutating func append(_ saved: [Transcript]) {
        var first = rows.count
        for row in saved.map(labeled) where row.sessionID == sessionID {
            var index = rows.count
            while index > 0 && Self.spokenBefore(row, rows[index - 1]) { index -= 1 }
            rows.insert(row, at: index)
            first = min(first, index)
        }
        guard first < rows.count else { return }
        regroup(from: first)
    }

    /// Puts cleaned text in place of the raw text of each row it names by id. Ids not shown are ignored.
    public mutating func replace(texts: [String: String]) {
        var first = rows.count
        for (id, text) in texts {
            guard let index = rows.lastIndex(where: { $0.id == id }) else { continue }
            rows[index].text = text
            first = min(first, index)
        }
        guard first < rows.count else { return }
        cleanupRevision += 1
        regroup(from: first)
    }

    /// Rows before `first` are unchanged, and so is the grouping of every paragraph that ends before it. New rows at the end continue the last paragraph; any other change regroups from the start of the paragraph that holds row `first`.
    private mutating func regroup(from first: Int) {
        let appendsOnly = first == folded.count
        // The paragraphs before `kept` keep their grouping.
        let kept: Int
        if appendsOnly {
            kept = paragraphs.count
        } else {
            // The paragraph that holds row `first`. The first paragraph starts at row 0, so there is always one.
            kept = paragraphStarts.lastIndex(where: { $0 <= first }) ?? 0
        }
        let start = kept < paragraphs.count ? paragraphStarts[kept] : first
        paragraphs.removeSubrange(kept...)
        paragraphStarts.removeSubrange(kept...)
        folded.removeSubrange(start...)
        for index in start..<rows.count {
            var row = rows[index]
            if let previous = folded.last {
                row = TranscriptGrouping.foldContinuation(row, after: previous, gap: gap)
            }
            folded.append(row)
            if let last = paragraphs.indices.last, TranscriptExport.canMerge(row, into: paragraphs[last], within: gap) {
                TranscriptExport.merge(row, into: &paragraphs[last])
            } else {
                paragraphs.append(row)
                paragraphStarts.append(index)
            }
        }
        revision += 1
    }

    private func labeled(_ row: Transcript) -> Transcript {
        var named = row
        named.speakerLabel = row.speakerID.flatMap { labels[$0] }
        return named
    }

    /// The order TranscriptStore.session(id:) reads: absolute start time, then id.
    private static func spokenBefore(_ row: Transcript, _ other: Transcript) -> Bool {
        let rowStart = row.startedAt.addingTimeInterval(row.startSeconds)
        let otherStart = other.startedAt.addingTimeInterval(other.startSeconds)
        return rowStart == otherStart ? row.id < other.id : rowStart < otherStart
    }
}
