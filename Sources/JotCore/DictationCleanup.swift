import Foundation

/// Delivery-only cleanup; recognized text in local history stays unchanged.
public enum DictationCleanup {
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
