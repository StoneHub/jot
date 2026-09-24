import Foundation

/// How a finished session's stored rows change when its words get new speakers. A row whose words keep one speaker only takes that speaker, so its id and cleaned text stay. A row whose speaker changes inside it splits there into pieces, and each piece takes its share of the row's cleaned text. Rows keep their live boundaries otherwise. Pure, so it is built outside the store lock.
public struct RowRelabel: Sendable {
    /// The words of one row that share a speaker, as a row of their own.
    public struct Piece: Sendable {
        public var text: String
        /// The piece's share of the row's cleaned text; empty when cleanup removed all of it, nil when the row was never cleaned.
        public var readable: String?
        public var speaker: String?
        public var start: Double
        public var end: Double
        /// Numbered from position 0 within the piece.
        public var words: [StoredWord]
    }

    public struct Split: Sendable {
        public var rowID: String
        public var pieces: [Piece]
    }

    /// Rows whose words all have one speaker, nil included.
    public private(set) var kept: [(rowID: String, speaker: String?)] = []
    public private(set) var splits: [Split] = []

    /// `speakers` holds one speaker per word of `words`; `readable` is the cleaned text by row id. Rows with no stored words are not in the plan.
    public init(words: [StoredWord], speakers: [String?], readable: [String: String]) throws {
        guard speakers.count == words.count else { throw StoreError.invalid("Relabeling needs one speaker per stored word") }
        var rowIDs: [String] = []
        var indexesByRow: [String: [Int]] = [:]
        for index in words.indices {
            let rowID = words[index].transcriptID
            if indexesByRow[rowID] == nil { rowIDs.append(rowID) }
            indexesByRow[rowID, default: []].append(index)
        }
        for rowID in rowIDs {
            let indexes = indexesByRow[rowID, default: []].sorted { words[$0].position < words[$1].position }
            let runs = Self.runs(of: indexes, speakers: speakers)
            if runs.count == 1 {
                kept.append((rowID: rowID, speaker: speakers[indexes[0]]))
                continue
            }
            var pieces: [Piece] = []
            for run in runs {
                let runWords = run.map { words[$0] }
                pieces.append(Self.piece(words: runWords, speaker: speakers[run[0]]))
            }
            if let cleaned = readable[rowID] {
                // A row is one inference block of at most 3 seconds, so its pieces stay far below distribute's 500-word cap.
                let shares = PhraseCleanup.distribute(cleaned, over: pieces.map(\.text))
                for index in pieces.indices {
                    pieces[index].readable = shares[index]
                }
            }
            splits.append(Split(rowID: rowID, pieces: pieces))
        }
    }

    /// Consecutive word indexes that share a speaker.
    private static func runs(of indexes: [Int], speakers: [String?]) -> [[Int]] {
        var result: [[Int]] = []
        for index in indexes {
            if let last = result.last?.last, speakers[last] == speakers[index] {
                result[result.count - 1].append(index)
            } else {
                result.append([index])
            }
        }
        return result
    }

    private static func piece(words: [StoredWord], speaker: String?) -> Piece {
        var renumbered = words
        for index in renumbered.indices {
            renumbered[index].position = index
        }
        let text = words.map(\.word).joined(separator: " ")
        return Piece(text: text, readable: nil, speaker: speaker, start: words[0].startSeconds, end: words[words.count - 1].endSeconds, words: renumbered)
    }
}
