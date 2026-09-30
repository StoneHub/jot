import Foundation

/// What the recognizer makes of a chair scrape, fidgeting or a throat clear when nobody is talking. Outside a held dictation, or in one the voice detector barely heard, a block made only of these words is not saved.
public enum NoiseFillers {
    /// Lowercased with everything but letters removed, so "Mm-hmm." is "mmhmm" and "Uh-huh" is "uhhuh".
    static let words: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "hmm", "hm", "mm", "mmm", "mhm", "mhmm", "mmhm", "mmhmm",
                                     "uhhuh", "ah", "oh", "yeah", "okay", "ok"]

    /// The voice detector's peak a held dictation of only these words needs to be kept. Holds with nothing said peaked at 0.38 to 0.49.
    public static let dictatedConfidence: Float = 0.6

    public static func isFillerOnly(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // A number is content: "Yeah, 20." is an answer.
        guard !tokens.contains(where: { $0.contains(where: \.isNumber) }) else { return false }
        let words = tokens.map { String($0.lowercased().filter(\.isLetter)) }.filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy(Self.words.contains)
    }
}
