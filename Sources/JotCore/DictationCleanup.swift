import Foundation

/// Delivery-only cleanup; recognized text in local history stays unchanged.
public enum DictationCleanup {
    public struct Prepared {
        public let text: String
        public let needsProseCleanup: Bool
    }

    /// Decide from recognition, before explicit symbols and preferred spellings are inserted.
    /// A lone word is an insertion, not prose for the model to capitalize or punctuate.
    public static func prepare(_ recognized: String, vocabulary: PersonalVocabulary = .init()) -> Prepared {
        let source = applying(to: recognized)
        let word = singleWord(source)
        let text = vocabulary.applyingToDictation(word ?? source)
        return Prepared(text: text, needsProseCleanup: word == nil && singleWord(text) == nil)
    }

    private static func singleWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[\\p{L}\\p{M}]+(?:['’\\-][\\p{L}\\p{M}]+)*\\.?$", options: .regularExpression) != nil else { return nil }
        guard trimmed.hasSuffix(".") else { return trimmed }
        let word = String(trimmed.dropLast())
        // Initials and common abbreviations own their dot. Internal dots, numbers,
        // URLs and ellipses do not match the lone-word pattern in the first place.
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc"]
        let initial = word.count == 1 && !["a", "i"].contains(word.lowercased())
        return initial || abbreviations.contains(word.lowercased()) ? trimmed : word
    }

    /// A standalone "uh" with the comma before it and the punctuation after it; compiled once, NSRegularExpression is immutable and thread-safe.
    private static let hesitation: NSRegularExpression = {
        let word = "[\\p{L}\\p{M}\\p{N}_'’\\-]"
        let pattern = "(?:,[ \\t]*)?(?<!" + word + ")uh(?!" + word + ")(?:[,;:]|\\.{1,3})?"
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    public static func applying(to text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard hesitation.firstMatch(in: text, range: range) != nil else { return text }
        let cleaned = hesitation.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^ +| +$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty ? "" : cleaned
    }
}
