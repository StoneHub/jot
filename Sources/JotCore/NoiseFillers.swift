import Foundation

/// What the recognizer makes of a chair scrape, fidgeting or a throat clear when nobody is talking. Outside a held dictation, a block made only of these words is not saved.
public enum NoiseFillers {
    /// Lowercased with everything but letters removed, so "Mm-hmm." is "mmhmm" and "Uh-huh" is "uhhuh".
    static let words: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "hmm", "hm", "mm", "mmm", "mhm", "mhmm", "mmhm", "mmhmm",
                                     "uhhuh", "ah", "oh", "yeah", "okay", "ok"]

    public static func isFillerOnly(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // A number is content: "Yeah, 20." is an answer.
        guard !tokens.contains(where: { $0.contains(where: \.isNumber) }) else { return false }
        let words = tokens.map { String($0.lowercased().filter(\.isLetter)) }.filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy(Self.words.contains)
    }
}
