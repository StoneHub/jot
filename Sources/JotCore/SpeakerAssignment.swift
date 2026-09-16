import Foundation

/// Maps the words of a session onto the speaker pass's segments. Pure, for the phase that relabels stored rows.
public enum SpeakerAssignment {
    /// Each word takes the speaker whose segment contains the word's midpoint. Where segments overlap there, the one covering more of the word wins; a word no segment contains gets nil.
    public static func assign(words: [(start: Double, end: Double)], segments: [(speaker: String, start: Double, end: Double)]) -> [String?] {
        words.map { word in
            let midpoint = (word.start + word.end) / 2
            let covering = segments.filter { $0.start <= midpoint && midpoint < $0.end }
            return covering.max { overlap($0, word) < overlap($1, word) }?.speaker
        }
    }

    private static func overlap(_ segment: (speaker: String, start: Double, end: Double), _ word: (start: Double, end: Double)) -> Double {
        max(0, min(segment.end, word.end) - max(segment.start, word.start))
    }
}
