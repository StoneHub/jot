import Foundation

/// Recognition rows are transport chunks, not independent sentences. Keep the
/// raw rows visible while assembling one bounded, same-speaker cleanup request.
public struct PhraseCleanup {
    public struct Phrase: Sendable {
        public let sources: [Transcript]
        public var text: String { sources.map(\.text).joined(separator: " ") }
    }
    private var pending: [Transcript] = []
    public var pendingCount: Int { pending.count }
    public init() {}

    public mutating func append(_ rows: [Transcript], final: Bool = false) -> [Phrase] {
        var ready: [Phrase] = []
        func flush() {
            if !pending.isEmpty { ready.append(Phrase(sources: pending)); pending = [] }
        }
        for row in rows where !row.text.isEmpty {
            if let last = pending.last, let first = pending.first,
               row.sessionID != last.sessionID || row.speakerID != last.speakerID ||
               row.startSeconds - last.endSeconds > 1.2 ||
               row.endSeconds - first.startSeconds > 12 ||
               pending.reduce(0, { $0 + $1.text.utf8.count + 1 }) + row.text.utf8.count > 2000 {
                flush()
            }
            pending.append(row)
            let text = pending.map(\.text).joined(separator: " ")
            if TranscriptGrouping.endsSentence(text) && text.split(whereSeparator: \.isWhitespace).count >= 8 {
                flush()
            }
        }
        if final { flush() }
        return ready
    }

    /// Map a whole-phrase edit back to stable source IDs. Exact word anchors keep
    /// removals/capitalization in the right rows; inserted wording follows its
    /// preceding anchor. No model-enforced array count or row boundary is needed.
    public static func distribute(_ cleaned: String, over sources: [Transcript]) -> [String] {
        guard !sources.isEmpty else { return [] }
        let original = sources.enumerated().flatMap { index, row in
            row.text.split(whereSeparator: \.isWhitespace).map { (String($0), index) }
        }
        let expression = try! NSRegularExpression(pattern: "\\S+\\s*")
        let value = cleaned as NSString
        let tokens = expression.matches(in: cleaned, range: NSRange(location: 0, length: value.length))
            .map { value.substring(with: $0.range) }
        func key(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let a = original.map { key($0.0) }, b = tokens.map(key)
        // Inputs already have a byte bound; cap alignment work too.
        guard a.count <= 500, b.count <= 500 else {
            return [cleaned] + Array(repeating: "", count: sources.count - 1)
        }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in (0..<a.count).reversed() {
                for j in (0..<b.count).reversed() {
                    lengths[i][j] = a[i] == b[j] ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var owners: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { owners[j] = original[i].1; i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        var result = Array(repeating: [String](), count: sources.count)
        var owner = owners.keys.min().flatMap { owners[$0] } ?? 0
        for index in tokens.indices {
            owner = owners[index] ?? owner
            result[owner].append(tokens[index])
        }
        return result.map { $0.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
