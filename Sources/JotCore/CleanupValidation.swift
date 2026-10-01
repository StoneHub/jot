import Foundation

/// Rejects known dangerous edits. This is a conservative fallback, not a proof of semantic equivalence.
public enum CleanupValidation {
    public static func accepts(_ candidate: String, source: String) -> Bool {
        let output = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.utf8.count <= max(120, source.utf8.count * 2) else { return false }
        let numbers = Set("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third half quarter percent point".split(separator: " ").map(String.init))
        let qualifiers = Set("no not never cannot can't don't doesn't didn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't hasn't hadn't maybe probably possibly might unless".split(separator: " ").map(String.init))
        func protected(_ text: String) -> [String] {
            let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'.,")).inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.filter { !$0.isEmpty }
            var result: [String] = []
            for word in words where numbers.contains(word) || qualifiers.contains(word) || word.contains(where: \.isNumber) {
                if result.last != word { result.append(word) }
            }
            return result
        }
        return protected(source) == protected(output)
    }
}
