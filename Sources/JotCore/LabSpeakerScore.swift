import Foundation

/// How well a transcript's speakers match the speakers its captions name, word by word. Speaker ids are arbitrary, so each
/// transcript speaker is paired with at most one caption speaker, the pairing that gets the most words right. A voice split
/// across two ids, or two voices under one id, gets credit for only one of them.
public struct LabSpeakerScore: Codable, Sendable, Equatable {
    /// Diarization error rate over time, in seconds of the captions' speech; the lab helper computes it with FluidAudio.
    public struct DiarizationError: Codable, Sendable, Equatable {
        /// The full width left unscored around each cue boundary: ±0.25 s, as NIST's md-eval scores, since caption times
        /// and recognized word times rarely agree to the frame.
        public static let collarSeconds = 0.5

        public var missedSeconds: Double
        public var falseAlarmSeconds: Double
        public var confusionSeconds: Double
        public var speechSeconds: Double
        public var rate: Double { speechSeconds == 0 ? 0 : (missedSeconds + falseAlarmSeconds + confusionSeconds) / speechSeconds }

        public init(missedSeconds: Double, falseAlarmSeconds: Double, confusionSeconds: Double, speechSeconds: Double) {
            self.missedSeconds = missedSeconds; self.falseAlarmSeconds = falseAlarmSeconds
            self.confusionSeconds = confusionSeconds; self.speechSeconds = speechSeconds
        }
    }

    /// Recognized words inside one caption speaker's cue: the words scored.
    public var words: Int
    /// Scored words whose speaker is paired with that cue's speaker.
    public var correct: Int
    /// Scored words whose stored row has no speaker, or overlap; they count as wrong, so leaving rows unlabeled never raises
    /// the score. Sessions shows an unlabeled row that continues a sentence under the speaker before it; the score does not.
    public var unattributed: Int
    /// Recognized words with no single caption speaker around them: in a pause between cues, outside the captions, or in a
    /// cue with no voice tag or one that overlaps another voice's. There is nothing to compare them with, so they are left out.
    public var unscored: Int
    /// Each transcript speaker and the caption speaker it was paired with.
    public var pairs: [String: String]
    /// Filled in by the lab helper.
    public var diarizationError: DiarizationError?

    public var accuracy: Double { words == 0 ? 0 : Double(correct) / Double(words) }

    /// `speakers` holds one speaker per word of `words`. Each word belongs to the cue around its midpoint. Nil when no cue
    /// names a speaker.
    public init?(words: [StoredWord], speakers: [String?], captions: [LabCaptions.Cue]) throws {
        guard speakers.count == words.count else { throw LabError.invalid("Speaker scoring needs one speaker per word.") }
        guard captions.contains(where: { $0.speaker != nil }) else { return nil }
        var counts: [String: [String: Int]] = [:]
        var scored = 0, unattributed = 0, unscored = 0
        for (word, speaker) in zip(words, speakers) {
            let middle = (word.startSeconds + word.endSeconds) / 2
            let around = captions.filter { $0.start <= middle && middle < $0.end }
            let voices = Set(around.compactMap(\.speaker))
            guard voices.count == 1, around.allSatisfy({ $0.speaker != nil }), let truth = voices.first else { unscored += 1; continue }
            scored += 1
            guard let speaker = Self.person(speaker) else { unattributed += 1; continue }
            counts[speaker, default: [:]][truth, default: 0] += 1
        }
        let ours = counts.keys.sorted(), theirs = Set(counts.values.flatMap(\.keys)).sorted()
        let matrix = ours.map { speaker in theirs.map { counts[speaker]?[$0] ?? 0 } }
        var pairs: [String: String] = [:]
        var correct = 0
        for (row, column) in Self.bestPairing(matrix).enumerated() {
            guard let column, matrix[row][column] > 0 else { continue }
            pairs[ours[row]] = theirs[column]
            correct += matrix[row][column]
        }
        self.words = scored; self.correct = correct; self.unattributed = unattributed; self.unscored = unscored; self.pairs = pairs
    }

    /// The speaker a row names, if it names one person: the live diarizer's "overlap" names no one.
    public static func person(_ speaker: String?) -> String? {
        speaker == "overlap" ? nil : speaker
    }

    /// Who spoke when, for the diarization error rate: the captions' cues, or stored rows with the speaker they have.
    /// Nil when a cue names no single speaker, since its speech would count as silence. Rows with no speaker are left
    /// out, so their time counts as missed speech.
    public static func segments(_ captions: [LabCaptions.Cue]) -> [(speaker: String, start: Double, end: Double)]? {
        guard captions.allSatisfy({ $0.speaker != nil }) else { return nil }
        return captions.compactMap { cue in cue.speaker.map { ($0, cue.start, cue.end) } }
    }

    public static func segments(_ rows: [LabRow], speaker: (LabRow) -> String?) -> [(speaker: String, start: Double, end: Double)] {
        rows.compactMap { row in person(speaker(row)).map { ($0, row.start, row.end) } }
    }

    /// The pairing of rows to columns, each used at most once, with the largest total: the Hungarian method on the square
    /// matrix of shortfalls from the largest count. Each row gets its column, or nil when it is left over.
    static func bestPairing(_ gains: [[Int]]) -> [Int?] {
        let rows = gains.count, columns = gains.first?.count ?? 0
        let n = max(rows, columns)
        guard rows > 0, columns > 0 else { return Array(repeating: nil, count: rows) }
        let top = gains.joined().max() ?? 0
        func cost(_ row: Int, _ column: Int) -> Int { row < rows && column < columns ? top - gains[row][column] : top }
        // 1-based potentials and matching; column 0 is the free slot each new row starts from.
        var u = [Int](repeating: 0, count: n + 1), v = [Int](repeating: 0, count: n + 1)
        var owner = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for row in 1...n {
            owner[0] = row
            var column = 0
            var least = [Int](repeating: .max, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[column] = true
                let current = owner[column]
                var delta = Int.max, next = 0
                for j in 1...n where !used[j] {
                    let reduced = cost(current - 1, j - 1) - u[current] - v[j]
                    if reduced < least[j] { least[j] = reduced; way[j] = column }
                    if least[j] < delta { delta = least[j]; next = j }
                }
                for j in 0...n {
                    if used[j] { u[owner[j]] += delta; v[j] -= delta } else { least[j] -= delta }
                }
                column = next
            } while owner[column] != 0
            repeat {
                let previous = way[column]
                owner[column] = owner[previous]
                column = previous
            } while column != 0
        }
        var result = [Int?](repeating: nil, count: rows)
        for column in 1...n where owner[column] <= rows && column <= columns { result[owner[column] - 1] = column - 1 }
        return result
    }
}
