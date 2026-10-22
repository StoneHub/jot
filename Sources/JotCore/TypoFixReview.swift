import Foundation

/// Decides whether a model result only fixes typos in the source, and builds the fixed text. Conservative: anything that
/// looks like a rewrite is rejected and the field stays as typed. The fixed text is the source with only the changed words
/// replaced, so the user's spacing, indentation and line breaks outside them are kept whatever the model did to them.
public enum TypoFixReview {
    public enum Result: Equatable, Sendable {
        /// `changes` counts the separate places fixed.
        case fixed(text: String, changes: Int)
        case unchanged
        /// `reason` is a code: empty, line-breaks, numbers, negation or rewrite.
        case rejected(reason: String)
    }

    public static func review(_ raw: String, source: String) -> Result {
        let output = unwrap(raw, source: source)
        guard !output.isEmpty else { return .rejected(reason: "empty") }
        guard newlines(in: output) == newlines(in: source) else { return .rejected(reason: "line-breaks") }
        guard numbers(in: output) == numbers(in: source) else { return .rejected(reason: "numbers") }
        let from = tokens(in: source), to = tokens(in: output)
        guard let regions = changedRegions(from.map(\.text), to.map(\.text)) else { return .rejected(reason: "rewrite") }
        // Spacing alone is left as typed: it may be indentation or alignment the user meant.
        guard !regions.isEmpty else { return .unchanged }
        let sourceCharacters = source.count
        var total = 0
        for region in regions {
            let before = from[region.source].map(\.text), after = to[region.output].map(\.text)
            let original = Array(before.joined(separator: " ")), fixed = Array(after.joined(separator: " "))
            let allowed = max(2, (max(original.count, fixed.count) + 1) / 2)
            let distance = repeatsNeighbor(region, in: from) ? 1 : TextDistance.optimalStringAlignment(original, fixed, limit: allowed)
            guard distance <= allowed else { return .rejected(reason: "rewrite") }
            guard negationsMatch(before, after) else { return .rejected(reason: "negation") }
            total += distance
        }
        guard total <= max(4, sourceCharacters * 2 / 5) else { return .rejected(reason: "rewrite") }
        return .fixed(text: rebuild(source, from: from, output: output, to: to, regions: regions), changes: regions.count)
    }

    // MARK: Output

    /// The model's text without the wrapper the prompt used, quotation marks around the whole result, or a label line.
    static func unwrap(_ raw: String, source: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<text>") { text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.hasSuffix("</text>") { text = String(text.dropLast(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("`", "`")]
        where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) && !trimmedSource.hasPrefix(open) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // "Corrected text:" on a line of its own, which the source does not have.
        if newlines(in: text) == newlines(in: trimmedSource) + 1, let end = text.firstIndex(of: "\n"),
           text[..<end].trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leading = source.prefix { $0.isWhitespace }, trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        return text.isEmpty ? "" : String(leading) + text + trailing
    }

    static func newlines(in text: String) -> Int { text.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } }

    /// Every word that contains a digit, in order and without surrounding punctuation.
    static func numbers(in text: String) -> [String] {
        tokens(in: text).map(\.text).filter { $0.contains(where: \.isNumber) }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
    }

    // MARK: Words

    struct Token {
        let text: String
        let range: Range<String.Index>
    }

    /// Runs of non-whitespace, with where each sits in the text.
    static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begun = start { result.append(Token(text: String(text[begun..<index]), range: begun..<index)); start = nil }
            } else if start == nil { start = index }
            index = text.index(after: index)
        }
        if let begun = start { result.append(Token(text: String(text[begun...]), range: begun..<text.endIndex)) }
        return result
    }

    struct Region: Equatable {
        let source: Range<Int>
        let output: Range<Int>
    }

    /// The stretches of words that differ, from a longest common subsequence of the two word lists. Nil when the lists are
    /// too long and different to compare cheaply, which is itself a rewrite.
    static func changedRegions(_ a: [String], _ b: [String]) -> [Region]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let x = Array(a[prefix..<(a.count - suffix)]), y = Array(b[prefix..<(b.count - suffix)])
        if x.isEmpty && y.isEmpty { return [] }
        guard x.count * y.count <= 1_000_000 else { return nil }
        // table[i][j]: common subsequence length of x[i...] and y[j...].
        let width = y.count + 1
        var table = [Int32](repeating: 0, count: (x.count + 1) * width)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i * width + j] = x[i] == y[j] ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var regions: [Region] = []
        var i = 0, j = 0, startI = 0, startJ = 0
        func close() {
            if i > startI || j > startJ { regions.append(Region(source: (prefix + startI)..<(prefix + i), output: (prefix + startJ)..<(prefix + j))) }
        }
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                close(); i += 1; j += 1; startI = i; startJ = j
            } else if j < y.count, i == x.count || table[i * width + j + 1] >= table[(i + 1) * width + j] {
                j += 1
            } else {
                i += 1
            }
        }
        close()
        return regions
    }

    /// Removing one word that repeats the word beside it, as in "the the", is a single typo however long the word.
    static func repeatsNeighbor(_ region: Region, in words: [Token]) -> Bool {
        guard region.output.isEmpty, region.source.count == 1 else { return false }
        let index = region.source.lowerBound, word = words[index].text.lowercased()
        return (index > 0 && words[index - 1].text.lowercased() == word)
            || (index + 1 < words.count && words[index + 1].text.lowercased() == word)
    }

    /// A negation may change only where a typo became it or stopped being it, such as "dont" or "nto": each one added or
    /// removed must be one edit away from a word on the other side.
    static func negationsMatch(_ before: [String], _ after: [String]) -> Bool {
        let from = before.map(normalized), to = after.map(normalized)
        func covered(_ words: [String], by others: [String]) -> Bool {
            var remaining = others
            for word in words where negations.contains(word) {
                if let same = remaining.firstIndex(of: word) { remaining.remove(at: same); continue }
                guard others.contains(where: { TextDistance.optimalStringAlignment(Array($0), Array(word), limit: 1) <= 1 }) else { return false }
            }
            return true
        }
        return covered(to, by: from) && covered(from, by: to) && !addsNegatingPrefix(from, to) && !addsNegatingPrefix(to, from)
    }

    /// "aggree" fixed to "disagree", or "possible" to "impossible": a fix that is the source word plus a prefix that reverses
    /// it. The stem may carry a typo of its own after dis-, un-, non- and mis-; after in-, im-, ir- and il- it must be the
    /// source word exactly, since a dropped first "i", as in "nformation", is a common typo.
    private static func addsNegatingPrefix(_ from: [String], _ to: [String]) -> Bool {
        to.contains { word in
            negatingPrefixes.contains { prefix, typos in
                guard word.hasPrefix(prefix), word.count > prefix.count + 2, !from.contains(where: { $0.hasPrefix(prefix) }) else { return false }
                let stem = Array(word.dropFirst(prefix.count))
                return from.contains { TextDistance.optimalStringAlignment(Array($0), stem, limit: typos) <= typos }
            }
        }
    }

    private static let negatingPrefixes = ["dis": 1, "un": 1, "non": 1, "mis": 1, "in": 0, "im": 0, "ir": 0, "il": 0]

    private static func normalized(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static let negations: Set<String> = Set(("no not never nor none nothing nobody cannot cant dont doesnt didnt wont "
        + "wouldnt shouldnt couldnt isnt arent wasnt werent havent hasnt hadnt aint").split(separator: " ").map(String.init))

    // MARK: Rebuilding

    /// The source with each changed stretch of words replaced by the model's, keeping all whitespace outside them.
    static func rebuild(_ source: String, from: [Token], output: String, to: [Token], regions: [Region]) -> String {
        var result = ""
        var cursor = source.startIndex
        for region in regions {
            var replacement = region.output.isEmpty ? ""
                : String(output[to[region.output.lowerBound].range.lowerBound..<to[region.output.upperBound - 1].range.upperBound])
            var range: Range<String.Index>
            if region.source.isEmpty {
                // Words the model added between two of the user's: insert them after the previous word, or before the first.
                if region.source.lowerBound > 0 {
                    let end = from[region.source.lowerBound - 1].range.upperBound
                    range = end..<end; replacement = " " + replacement
                } else if let first = from.first {
                    range = first.range.lowerBound..<first.range.lowerBound; replacement += " "
                } else {
                    return replacement
                }
            } else {
                range = from[region.source.lowerBound].range.lowerBound..<from[region.source.upperBound - 1].range.upperBound
                if replacement.isEmpty {
                    // Removing words also removes the space after them, or before them at the end of a line.
                    let after = source[range.upperBound...].prefix { $0.isWhitespace && !$0.isNewline }
                    if !after.isEmpty { range = range.lowerBound..<after.endIndex }
                    else {
                        let before = source[cursor..<range.lowerBound].reversed().prefix { $0.isWhitespace && !$0.isNewline }
                        range = source.index(range.lowerBound, offsetBy: -before.count)..<range.upperBound
                    }
                }
            }
            result += source[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        return result + source[cursor...]
    }
}
