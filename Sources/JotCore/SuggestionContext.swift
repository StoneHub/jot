import CoreGraphics
import Foundation

/// Read from the existing store on a background executor. No second transcript database or inferred speaker identity.
public struct SuggestionContext: Sendable {
    public let rows: [Transcript]
    public let sources: [Source]
    public let sessionTitle: String?

    public init(rows: [Transcript], sessionTitle: String?) {
        self.rows = rows; self.sessionTitle = sessionTitle
        let date = ISO8601DateFormatter()
        sources = rows.map { row in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(row)) ?? Data()
            let revision = Int(ContentHash.sha256(data).prefix(12), radix: 16) ?? 1
            return Source(id: row.id, kind: row.mode == "dictation" ? "dictation" : "meeting-transcript",
                          role: row.mode == "dictation" ? "user" : "participant",
                          speaker: row.mode == "dictation" ? nil : (row.speakerLabel ?? "unlabeled speaker"),
                          origin: "jot", scope: Source.Scope(session: row.sessionID),
                          timestamp: date.string(from: row.startedAt.addingTimeInterval(row.startSeconds)),
                          revision: revision, status: .current, text: row.text)
        }
    }
    public func input(target: Target, association: ContextAssociation = .explicitRecentRequest) -> ScenarioInput {
        var input = ScenarioInput(target: target, sources: sources)
        input.association = association
        return input
    }
    public func attribution(selected: [Source]) -> String {
        var parts: [String] = []
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("Recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "Meeting ‘\($0)’" } ?? "Latest session")
        }
        return parts.joined(separator: " + ")
    }
}

extension SuggestionContext {
    /// Stored rows a request may use. Recent dictation backs only a blank Codex composer, and the latest meeting
    /// joins only when the user adds it on the card or makes it the default. Recency alone adds neither.
    public func requestSources(dictation: Bool, meeting: Bool) -> [Source] {
        sources.filter { ($0.kind == "dictation" && dictation) || ($0.kind == "meeting-transcript" && meeting) }
    }

    /// How the card offers the latest meeting, or nil when none was recorded in the window.
    public var meetingName: String? {
        guard sources.contains(where: { $0.kind == "meeting-transcript" }) else { return nil }
        return sessionTitle.map { "meeting ‘\($0)’" } ?? "the latest meeting"
    }
}

extension SelectionLimits {
    /// A meeting the user adds brings many short phrases. Still well inside the on-device context window.
    public static let withMeeting = SelectionLimits(maximumSources: 12, maximumSourceBytes: 5000)
}

/// One run of visible text read through Accessibility, in Accessibility screen coordinates (origin top-left, y down).
public struct ScreenText: Equatable, Sendable {
    public init(_ text: String, frame: CGRect) { self.text = text; self.frame = frame }
    public let text: String
    public let frame: CGRect
}

/// Visible text above the focused field in its own window: in a chat, the conversation, newest last. It is
/// associated with the target by position, not by recency, so another chat or a sidebar is not included.
/// Authors are not identified; the prompt says so. No app-specific parsing, and nothing is stored.
public enum ScreenContext {
    public static let kind = "screen-text"
    /// Leaves room for recent dictation within the selector's 4 KiB bound.
    public static let maximumBytes = 2400

    /// Keeps text in the field's column that is at least half visible and entirely above the field, joins runs on
    /// one line, and keeps the lines nearest the field within `maximumBytes`.
    public static func excerpt(_ items: [ScreenText], field: CGRect, visible: CGRect,
                               maximumBytes: Int = ScreenContext.maximumBytes) -> String? {
        let column = field.insetBy(dx: -field.width * 0.15, dy: 0)
        let kept = items.filter { item in
            let frame = item.frame
            guard frame.width > 0, frame.height > 0, frame.maxY <= field.minY + 2,
                  frame.midX >= column.minX, frame.midX <= column.maxX,
                  !collapsed(item.text).isEmpty else { return false }
            let shown = frame.intersection(visible)
            return !shown.isNull && shown.width * shown.height >= frame.width * frame.height * 0.5
        }.sorted { a, b in
            abs(a.frame.minY - b.frame.minY) > 0.5 ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
        }
        var lines: [(text: String, top: CGFloat, bottom: CGFloat, gapBefore: CGFloat)] = []
        for item in kept {
            let text = collapsed(item.text)
            if let last = lines.last, item.frame.midY >= last.top, item.frame.midY <= last.bottom {
                let joined = last.text.hasSuffix(" ") || text.first.map({ ".,;:!?)".contains($0) }) == true
                    ? last.text + text : last.text + " " + text
                lines[lines.count - 1] = (joined, last.top, max(last.bottom, item.frame.maxY), last.gapBefore)
            } else if lines.last?.text != text {
                lines.append((text, item.frame.minY, item.frame.maxY, lines.last.map { item.frame.minY - $0.bottom } ?? 0))
            }
        }
        var chosen: [String] = []
        var bytes = 0
        for (index, line) in lines.enumerated().reversed() {
            // A visible gap between lines usually separates messages or paragraphs.
            let separator = index + 1 < lines.count && lines[index + 1].gapBefore > 6 ? "\n\n" : "\n"
            let cost = line.text.utf8.count + (chosen.isEmpty ? 0 : separator.utf8.count)
            if bytes + cost > maximumBytes {
                if chosen.isEmpty { chosen.append(tail(line.text, maximumBytes: maximumBytes)) }
                break
            }
            chosen.insert(chosen.isEmpty ? line.text : line.text + separator, at: 0)
            bytes += cost
        }
        let text = chosen.joined()
        return text.isEmpty ? nil : text
    }

    public static func source(_ excerpt: String, at date: Date) -> Source {
        Source(id: "screen", kind: kind, role: "unknown", origin: "accessibility", scope: Source.Scope(),
               timestamp: ISO8601DateFormatter().string(from: date),
               revision: Int(ContentHash.sha256(excerpt).prefix(12), radix: 16) ?? 1, status: .current, text: excerpt)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The end of an over-long line, the part nearest the field.
    private static func tail(_ text: String, maximumBytes: Int) -> String {
        var tail = Substring(text)
        while tail.utf8.count > maximumBytes { tail = tail.dropFirst(max(1, (tail.utf8.count - maximumBytes) / 4)) }
        return String(tail)
    }
}

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
        public let source: Source
    }

    /// Each ambient row is read with a close neighbour on each side from its session, so a sentence split across short
    /// rows still matches. Only the sentences that share words with the notes are kept, with any between them: the
    /// model appends a neighbouring sentence it is shown, even one the notes never mention. nil when nothing shares
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
        return Match(rows: best.rows, source: Source(
            id: "heard", kind: kind, role: "unknown", speaker: oneSpeaker ? first.speakerLabel : nil, origin: "jot",
            scope: Source.Scope(session: first.sessionID), timestamp: ISO8601DateFormatter().string(from: start(first)),
            revision: Int(ContentHash.sha256(best.text).prefix(12), radix: 16) ?? 1, status: .current, text: best.text))
    }

    /// The selected sources with the heard speech added, oldest first. It was bounded on its own, so the selector's
    /// recency order cannot drop it. A meeting row it repeats is left out.
    public static func adding(_ match: Match?, to selected: [Source]) -> [Source] {
        guard let match else { return selected }
        let ids = Set(match.rows.map(\.id))
        var sources = selected.filter { !ids.contains($0.id) }
        sources.insert(match.source, at: sources.firstIndex { $0.timestamp > match.source.timestamp } ?? sources.count)
        return sources
    }

    private static func start(_ row: Transcript) -> Date { row.startedAt.addingTimeInterval(row.startSeconds) }

    /// From the first to the last sentence that shares a run or two distinctive words with the notes, and the rows those
    /// sentences come from. A row that ends without . ! ? or … runs on into the next. Rows by different named speakers
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
        guard let first = shares.firstIndex(of: true), let last = shares.lastIndex(of: true) else { return nil }
        let parts = sentences[first...last].flatMap { $0 }
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

/// The card's source line: whose words the suggestion came from, in plain terms.
public enum SuggestionAttribution {
    public static func line(plan: SuggestionPlan, selected: [Source], sessionTitle: String?) -> String {
        var parts: [String] = []
        if case .draft(let seed) = plan { parts.append(seed.isSelection ? "Your selection" : "Your notes") }
        if selected.contains(where: { $0.kind == ScreenContext.kind }) { parts.append("text on screen") }
        if selected.contains(where: { $0.kind == HeardSpeech.kind }) { parts.append("what Jot heard") }
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "meeting ‘\($0)’" } ?? "the latest meeting")
        }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        return parts.joined(separator: " + ")
    }
}
