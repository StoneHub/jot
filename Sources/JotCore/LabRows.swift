import Foundation

/// Builds a variant's rows from one recognition run's saved rows and words, the way Regroup and the speaker pass rewrite a
/// session: `RowRelabel` keeps or splits each row by the final speakers, and every resulting row also reports its live speaker.
public enum LabRows {
    /// `liveSpeakers` and `passSpeakers` hold one speaker per word of `words`; without a pass, the live speakers split the rows.
    public static func rows(rows: [Transcript], words: [StoredWord], readable: [String: String],
                            liveSpeakers: [String?], passSpeakers: [String?]?) throws -> [LabRow] {
        guard liveSpeakers.count == words.count, passSpeakers.map({ $0.count == words.count }) ?? true else {
            throw LabError.invalid("The lab needs one speaker per stored word.")
        }
        let plan = try RowRelabel(words: words, speakers: passSpeakers ?? liveSpeakers, readable: readable)
        var indexesByRow: [String: [Int]] = [:]
        for index in words.indices { indexesByRow[words[index].transcriptID, default: []].append(index) }
        for rowID in indexesByRow.keys { indexesByRow[rowID]?.sort { words[$0].position < words[$1].position } }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func live(_ indexes: some Collection<Int>) -> String? {
            var counts: [String?: Int] = [:]
            var order: [String?] = []
            for index in indexes {
                let speaker = liveSpeakers[index]
                if counts[speaker] == nil { order.append(speaker) }
                counts[speaker, default: 0] += 1
            }
            return order.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? nil
        }

        var result: [LabRow] = []
        for kept in plan.kept {
            guard let row = byID[kept.rowID], let indexes = indexesByRow[kept.rowID] else { continue }
            // The store reads a cleaned row back with its cleaned text; the words are what was recognized.
            let raw = indexes.map { words[$0].word }.joined(separator: " ")
            let cleaned = readable[kept.rowID]
            result.append(LabRow(start: row.startSeconds, end: row.endSeconds, liveSpeaker: live(indexes),
                passSpeaker: passSpeakers == nil ? nil : kept.speaker, rawText: raw, cleanedText: cleaned,
                cleanup: outcome(raw: raw, cleaned: cleaned)))
        }
        for split in plan.splits {
            guard let indexes = indexesByRow[split.rowID] else { continue }
            var next = 0
            for piece in split.pieces {
                let pieceIndexes = indexes[next..<(next + piece.words.count)]
                next += piece.words.count
                result.append(LabRow(start: piece.start, end: piece.end, liveSpeaker: live(pieceIndexes),
                    passSpeaker: passSpeakers == nil ? nil : piece.speaker, rawText: piece.text, cleanedText: piece.readable,
                    cleanup: outcome(raw: piece.text, cleaned: piece.readable)))
            }
        }
        // Rows saved without words pass through; their raw text is lost if they were cleaned.
        for row in rows where indexesByRow[row.id] == nil && row.mode == "ambient" {
            let cleaned = readable[row.id]
            result.append(LabRow(start: row.startSeconds, end: row.endSeconds, liveSpeaker: row.speakerID, passSpeaker: nil,
                rawText: row.text, cleanedText: cleaned, cleanup: outcome(raw: row.text, cleaned: cleaned)))
        }
        return result.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The paragraphs Sessions and export show for `rows`: unattributed continuations folded into the speaker before them,
    /// then consecutive rows of one speaker joined while the pause between them stays under the paragraph pause.
    /// After a speaker pass the app shows only pass speakers, an unlabeled row included; without one, the live speakers.
    public static func paragraphs(_ rows: [LabRow], tuning: TranscriptionTuning) -> [LabRow] {
        let pause = tuning.bounded.paragraphPause
        let start = Date(timeIntervalSince1970: 0)
        let hasPass = rows.contains { $0.passSpeaker != nil }
        let shown = rows.enumerated().map { index, row in
            Transcript(id: String(index), sessionID: "lab", startedAt: start, startSeconds: row.start, endSeconds: row.end,
                text: row.cleanedText ?? row.rawText, speakerID: hasPass ? row.passSpeaker : row.liveSpeaker, mode: "ambient")
        }
        var result: [LabRow] = []
        var paragraph: Transcript?
        for row in TranscriptGrouping.foldContinuations(shown, gap: pause) {
            guard let index = Int(row.id) else { continue }
            var source = rows[index]
            if var current = paragraph, TranscriptExport.canMerge(row, into: current, within: pause) {
                TranscriptExport.merge(row, into: &current)
                paragraph = current
                result[result.count - 1] = joined(result[result.count - 1], source)
            } else {
                // A folded continuation takes the speaker it continues.
                if row.speakerID != shown[index].speakerID {
                    if hasPass { source.passSpeaker = row.speakerID }
                    else { source.liveSpeaker = row.speakerID }
                }
                paragraph = row
                result.append(source)
            }
        }
        return result
    }

    private static func joined(_ first: LabRow, _ next: LabRow) -> LabRow {
        func join(_ a: String, _ b: String) -> String { [a, b].filter { !$0.isEmpty }.joined(separator: " ") }
        var result = first
        result.end = max(first.end, next.end)
        result.rawText = join(first.rawText, next.rawText)
        if first.cleanedText != nil || next.cleanedText != nil {
            result.cleanedText = join(first.cleanedText ?? first.rawText, next.cleanedText ?? next.rawText)
        }
        let outcomes = [first.cleanup, next.cleanup]
        result.cleanup = outcomes.contains(.changed) ? .changed
            : outcomes.allSatisfy { $0 == .removed } ? .removed
            : outcomes.allSatisfy { $0 == .noCleanedText } ? .noCleanedText
            : outcomes.contains(.removed) ? .changed : .unchanged
        return result
    }

    static func outcome(raw: String, cleaned: String?) -> LabRow.Cleanup {
        guard let cleaned else { return .noCleanedText }
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .removed }
        return WordErrorRate.words(raw) == WordErrorRate.words(cleaned) ? .unchanged : .changed
    }
}
