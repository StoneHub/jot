import Foundation

/// Word error rate between reference text and a transcript: substitutions, deletions and insertions over the reference's
/// words, after lowercasing and dropping punctuation outside words. Two rows of the edit table are kept, so a long recording
/// costs time in proportion to the product of the lengths but little memory.
public enum WordErrorRate {
    public struct Score: Codable, Sendable, Equatable {
        public var referenceWords: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var rate: Double { referenceWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceWords) }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = words(reference), hyp = words(hypothesis)
        // Each cell: total edits, then substitutions, deletions and insertions on the cheapest path.
        typealias Cell = (cost: Int, s: Int, d: Int, i: Int)
        var previous: [Cell] = (0...hyp.count).map { ($0, 0, 0, $0) }
        for r in 1...max(1, ref.count) where !ref.isEmpty {
            var current: [Cell] = [(r, 0, r, 0)]
            for h in 1...max(1, hyp.count) where !hyp.isEmpty {
                let same = ref[r - 1] == hyp[h - 1]
                let diagonal = previous[h - 1]
                var best: Cell = same ? diagonal : (diagonal.cost + 1, diagonal.s + 1, diagonal.d, diagonal.i)
                let up = previous[h]
                if up.cost + 1 < best.cost { best = (up.cost + 1, up.s, up.d + 1, up.i) }
                let left = current[h - 1]
                if left.cost + 1 < best.cost { best = (left.cost + 1, left.s, left.d, left.i + 1) }
                current.append(best)
            }
            previous = current
        }
        let last = previous[previous.count - 1]
        return Score(referenceWords: ref.count, substitutions: last.s, deletions: last.d, insertions: last.i)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines).compactMap { token in
            let word = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            return word.isEmpty ? nil : word
        }
    }
}
