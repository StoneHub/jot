import Foundation

/// Speech Jot heard that a draft's notes quote or paraphrase, such as a line from a video the user is writing about.
/// Speech joins by the distinctive words and three-word runs it shares with the notes, never by recency, so unrelated
/// speech stays out of the prompt. Pure: the caller reads the store off the main thread.
public enum HeardSpeech {
    public static let kind = "heard-speech"
    /// How far back a draft looks for speech it may quote.
    public static let lookback: TimeInterval = 60 * 60
    /// Rows read for one match; an hour of listening is usually well under this.
    public static let candidateLimit = 2000
    /// A row and its neighbours fit beside the screen excerpt inside the selector's 4 KiB.
    public static let maximumBytes = 1600
    /// A neighbour further from the row than this is a different moment, not the rest of the sentence.
    static let neighbourGap: TimeInterval = 30

    /// The speech the notes quote: the rows it came from, which are revalidated before Tab, and the source the prompt shows.
    public struct Match: Equatable, Sendable {
        public let rows: [Transcript]
        public let source: SuggestionSource
    }

    /// Each ambient row is read with a close neighbour on each side from its session, so a sentence split across short
    /// rows still matches. Only sentences that share distinctive words with the notes are kept: the
    /// model may append an unrelated sentence if it is shown one. nil when nothing shares
    /// enough. Among equal matches, the row that matches best on its own, then the newer, wins.
    public static func match(notes: String, rows: [Transcript]) -> Match? {
        let wanted = Terms(notes)
        guard wanted.distinctive.count >= 3 else { return nil }
        let sessions = Dictionary(grouping: rows.filter { $0.mode == "ambient" }, by: \.sessionID).values.map { rows in
            rows.sorted { start($0) != start($1) ? start($0) < start($1) : $0.id < $1.id }
        }
        var best: (key: (Int, Int, Date), text: String, rows: [Transcript])?
        for session in sessions {
            for index in session.indices {
                guard let (text, kept) = excerpt(neighbourhood(session, around: index), notes: wanted),
                      let score = wanted.overlap(with: Terms(text)) else { continue }
                let own = wanted.shared(with: Terms(session[index].text))
                let key = (score, own.words + own.runs, start(session[index]))
                if best.map({ key > $0.key }) ?? true { best = (key, text, kept) }
            }
        }
        guard let best, let first = best.rows.first else { return nil }
        let oneSpeaker = Set(best.rows.map(\.speakerLabel)).count == 1
        return Match(rows: best.rows, source: SuggestionSource(
            id: "heard", kind: kind, role: "unknown", speaker: oneSpeaker ? first.speakerLabel : nil, origin: "jot",
            scope: SuggestionSource.Scope(session: first.sessionID), timestamp: ISO8601DateFormatter().string(from: start(first)),
            revision: Int(ContentHash.sha256(best.text).prefix(12), radix: 16) ?? 1, status: .current, text: best.text))
    }

    /// Add a matched quote without repeating a grouped speech turn or exceeding the prompt source bounds.
    public static func adding(_ match: Match?, to selected: [SuggestionSource],
                              members: (SuggestionSource) -> [Transcript] = { _ in [] }, limits: SelectionLimits = .window) -> [SuggestionSource] {
        addition(match, to: selected, members: members, limits: limits).selected
    }

    public struct Addition: Sendable {
        public let selected: [SuggestionSource]
        /// Selected speech replaced by the matching heard sentence because it shares backing rows.
        public let duplicateSpeechCount: Int
        /// Selected speech dropped to keep the final prompt inside its source and byte limits.
        public let overLimitSpeechCount: Int
    }

    /// The final prompt inputs and the two reasons an earlier selected speech source stopped being used.
    public static func addition(_ match: Match?, to selected: [SuggestionSource],
                                members: (SuggestionSource) -> [Transcript] = { _ in [] }, limits: SelectionLimits = .window) -> Addition {
        guard let match else { return Addition(selected: selected, duplicateSpeechCount: 0, overLimitSpeechCount: 0) }
        let ids = Set(match.rows.map(\.id))
        var sources = selected.filter { source in
            !ids.contains(source.id) && members(source).allSatisfy { !ids.contains($0.id) }
        }
        let duplicateCount = selected.count - sources.count
        guard match.source.text.utf8.count <= limits.maximumSourceBytes else {
            return Addition(selected: selected, duplicateSpeechCount: 0, overLimitSpeechCount: 0)
        }
        var evictedCount = 0
        while sources.count + 1 > limits.maximumSources ||
              sources.reduce(match.source.text.utf8.count, { $0 + $1.text.utf8.count }) > limits.maximumSourceBytes {
            guard let oldestSpeech = sources.firstIndex(where: { $0.kind == "meeting-transcript" || $0.kind == "dictation" }) else {
                return Addition(selected: selected, duplicateSpeechCount: 0, overLimitSpeechCount: 0)
            }
            sources.remove(at: oldestSpeech)
            evictedCount += 1
        }
        sources.insert(match.source, at: sources.firstIndex { $0.timestamp > match.source.timestamp } ?? sources.count)
        return Addition(selected: sources, duplicateSpeechCount: duplicateCount, overLimitSpeechCount: evictedCount)
    }

    private static func start(_ row: Transcript) -> Date { row.startedAt.addingTimeInterval(row.startSeconds) }

    /// Each sentence that shares a run or two distinctive words with the notes, and the rows those sentences came from.
    /// A row that ends without . ! ? or … runs on into the next. Rows by different named speakers
    /// keep their names line by line.
    private static func excerpt(_ rows: [Transcript], notes: Terms) -> (text: String, rows: [Transcript])? {
        var sentences: [[(row: Int, text: String)]] = []
        var open = false
        for (index, row) in rows.enumerated() {
            for piece in pieces(of: row.text) {
                if open && !sentences.isEmpty { sentences[sentences.count - 1].append((index, piece.text)) }
                else { sentences.append([(index, piece.text)]) }
                open = !piece.ends
            }
        }
        let shares = sentences.map { sentence in
            let shared = notes.shared(with: Terms(sentence.map(\.text).joined(separator: " ")))
            return shared.words >= 2 || shared.runs >= 1
        }
        guard shares.contains(true) else { return nil }
        let parts = zip(sentences, shares).flatMap { sentence, relevant in relevant ? sentence : [] }
        var kept: [Int] = []
        for part in parts where kept.last != part.row { kept.append(part.row) }
        let text = Set(kept.map { rows[$0].speakerLabel }).count == 1 ? parts.map(\.text).joined(separator: " ")
            : kept.map { row in
                "\(rows[row].speakerLabel ?? "Unidentified speaker"): " + parts.filter { $0.row == row }.map(\.text).joined(separator: " ")
            }.joined(separator: "\n")
        return (text, kept.map { rows[$0] })
    }

    /// A row's sentences, each marked when it ends with . ! ? or …, before any closing quote or bracket.
    private static func pieces(of text: String) -> [(text: String, ends: Bool)] {
        var pieces: [(text: String, ends: Bool)] = []
        var current = "", ended = false
        for character in text {
            if ended && character.isWhitespace { pieces.append((current, true)); current = ""; ended = false; continue }
            current.append(character)
            if ".!?…".contains(character) { ended = true } else if !"\"'”’)]".contains(character) { ended = false }
        }
        pieces.append((current, ended))
        return pieces.map { ($0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.ends) }.filter { !$0.text.isEmpty }
    }

    /// The row, then the next and the previous row when they are close in time and fit `maximumBytes`. A row that alone
    /// is over the bound is skipped.
    private static func neighbourhood(_ session: [Transcript], around index: Int) -> [Transcript] {
        var bytes = session[index].text.utf8.count
        guard bytes <= maximumBytes else { return [] }
        var lower = index, upper = index
        for neighbour in [index + 1, index - 1] where session.indices.contains(neighbour) {
            let (earlier, later) = neighbour > index ? (session[index], session[neighbour]) : (session[neighbour], session[index])
            let size = session[neighbour].text.utf8.count + 1
            guard start(later).timeIntervalSince(earlier.startedAt.addingTimeInterval(earlier.endSeconds)) <= neighbourGap,
                  bytes + size <= maximumBytes else { continue }
            bytes += size
            lower = min(lower, neighbour); upper = max(upper, neighbour)
        }
        return Array(session[lower...upper])
    }

    /// Words that say what a text is about, and three-word runs that hold one of them. Function words, fillers and
    /// short words never count, so speech that shares only "it's not really a" does not match.
    struct Terms {
        let distinctive: Set<String>
        let runs: Set<String>

        init(_ text: String) {
            let words = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
            distinctive = Set(words.filter(Self.isDistinctive))
            runs = words.count < 3 ? [] : Set((0...(words.count - 3)).compactMap { index in
                let run = words[index..<index + 3]
                return run.contains(where: Self.isDistinctive) ? run.joined(separator: " ") : nil
            })
        }

        func shared(with other: Terms) -> (words: Int, runs: Int) {
            (distinctive.intersection(other.distinctive).count, runs.intersection(other.runs).count)
        }

        /// A quote shares at least two runs and three words; a paraphrase shares at least four words, and at least half
        /// of the smaller side's. nil below that; otherwise higher for more shared words and runs.
        func overlap(with heard: Terms) -> Int? {
            let (words, runs) = shared(with: heard)
            let quotes = runs >= 2 && words >= 3
            let paraphrases = words >= 4 && words * 2 >= min(distinctive.count, heard.distinctive.count)
            return quotes || paraphrases ? words + runs : nil
        }

        static func isDistinctive(_ word: String) -> Bool {
            word.contains(where: \.isNumber) || (word.count >= 3 && !stopwords.contains(word))
        }

        static let stopwords: Set<String> = [
            "about", "actually", "after", "again", "all", "also", "and", "any", "anything", "are", "aren't", "around",
            "back", "basically", "because", "been", "before", "being", "but", "can", "can't", "cant", "come", "could",
            "did", "didn't", "didnt", "does", "doesn't", "doesnt", "doing", "don't", "dont", "down", "even", "every",
            "everything", "for", "from", "get", "gets", "getting", "going", "gonna", "good", "got", "had", "has", "have",
            "he's", "her", "here", "hers", "him", "his", "how", "i'd", "i'll", "i'm", "i've", "into", "isn't", "it's",
            "its", "just", "kind", "know", "let's", "like", "literally", "look", "lot", "made", "make", "many", "maybe",
            "mean", "might", "more", "most", "much", "must", "need", "not", "now", "off", "okay", "one", "only", "other",
            "our", "out", "over", "pretty", "really", "right", "said", "same", "say", "says", "see", "she", "she's",
            "should", "some", "something", "sort", "still", "stuff", "such", "sure", "take", "than", "that", "that's",
            "thats", "the", "their", "them", "then", "there", "there's", "these", "they", "they're", "thing", "things",
            "think", "this", "those", "through", "too", "try", "uhm", "umm", "very", "wanna", "want", "was", "wasn't",
            "way", "we'll", "we're", "well", "went", "were", "what", "what's", "when", "where", "which", "while", "who",
            "why", "will", "with", "won't", "would", "yeah", "yes", "yet", "you", "you'd", "you'll", "you're", "you've",
            "your", "yours",
        ]
    }
}
