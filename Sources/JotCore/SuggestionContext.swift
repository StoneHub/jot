import CoreGraphics
import Foundation

/// Speech from the suggestion window, read from the existing store on a background executor. No second transcript
/// database. Rows become sources the way a reader would take them:
/// - Consecutive ambient rows from one voice a moment apart are one turn, so a sentence recognized in three-second
///   pieces arrives whole, and ten minutes of speech fit the selector's twelve sources.
/// - An ambient row heard during a dictation hold repeats that dictation, so only the dictation is kept.
/// - The voice heard during the holds of a session is the user's: its other rows in that session are the user's words.
/// - A named voice is that participant. Any other voice is unidentified, which the prompt says may be the user.
public struct SuggestionContext: Sendable {
    public let rows: [Transcript]
    public let sources: [Source]
    public let sessionTitle: String?
    /// The rows each source was built from, by source id.
    private let members: [String: [Transcript]]
    /// Rows from one voice at most this far apart read as one turn.
    static let turnGap: TimeInterval = 1.5

    public init(rows: [Transcript], sessionTitle: String?) {
        self.rows = rows; self.sessionTitle = sessionTitle
        let dictations = rows.filter { $0.mode == "dictation" }
        var heldSeconds: [String: [String: Double]] = [:]
        var heard: [Transcript] = []
        for row in rows where row.mode != "dictation" {
            let held = dictations.filter { $0.sessionID == row.sessionID }.reduce(0.0) { total, hold in
                total + max(0, min(Self.end(hold), Self.end(row)) - max(Self.start(hold), Self.start(row)))
            }
            guard held * 2 < max(Self.end(row) - Self.start(row), 0.01) else {
                if let voice = row.speakerID { heldSeconds[row.sessionID, default: [:]][voice, default: 0] += held }
                continue
            }
            heard.append(row)
        }
        let userVoice = heldSeconds.compactMapValues { voices in voices.max { $0.value < $1.value }?.key }
        var groups = dictations.map { [$0] }
        for row in heard.sorted(by: { Self.start($0) != Self.start($1) ? Self.start($0) < Self.start($1) : $0.id < $1.id }) {
            if let last = groups.last?.last, last.mode != "dictation", last.sessionID == row.sessionID,
               last.speakerID == row.speakerID, last.speakerLabel == row.speakerLabel,
               Self.start(row) - Self.end(last) <= Self.turnGap {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        groups.sort { Self.start($0[0]) != Self.start($1[0]) ? Self.start($0[0]) < Self.start($1[0]) : $0[0].id < $1[0].id }
        let date = ISO8601DateFormatter()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        sources = groups.map { group in
            let first = group[0]
            let revision = Int(ContentHash.sha256((try? encoder.encode(group)) ?? Data()).prefix(12), radix: 16) ?? 1
            let role: String, speaker: String?
            if first.mode == "dictation" { role = "user"; speaker = nil }
            else if let voice = first.speakerID, userVoice[first.sessionID] == voice { role = "user"; speaker = first.speakerLabel }
            else if let label = first.speakerLabel { role = "participant"; speaker = label }
            else { role = "unknown"; speaker = first.speakerID.map { $0.replacingOccurrences(of: "-", with: " ") } }
            return Source(id: first.id, kind: first.mode == "dictation" ? "dictation" : "meeting-transcript",
                          role: role, speaker: speaker, origin: "jot", scope: Source.Scope(session: first.sessionID),
                          timestamp: date.string(from: first.startedAt.addingTimeInterval(first.startSeconds)),
                          revision: revision, status: .current, text: group.map(\.text).joined(separator: " "))
        }
        members = Dictionary(uniqueKeysWithValues: groups.map { ($0[0].id, $0) })
    }

    /// The rows behind these sources: what must be unchanged when the suggestion is accepted.
    public func rows(for sources: [Source]) -> [Transcript] { sources.flatMap { members[$0.id] ?? [] } }

    public func input(target: Target, association: ContextAssociation = .explicitRecentRequest) -> ScenarioInput {
        var input = ScenarioInput(target: target, sources: sources)
        input.association = association
        return input
    }

    private static func start(_ row: Transcript) -> TimeInterval { row.startedAt.timeIntervalSince1970 + row.startSeconds }
    private static func end(_ row: Transcript) -> TimeInterval { row.startedAt.timeIntervalSince1970 + row.endSeconds }
}

extension SelectionLimits {
    /// Ten minutes of speech and agent messages come as many short pieces. Still inside the on-device context window;
    /// the selector keeps the newest when the bound forces a choice.
    public static let window = SelectionLimits(maximumSources: 12, maximumSourceBytes: 6000)
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
        return Match(rows: best.rows, source: Source(
            id: "heard", kind: kind, role: "unknown", speaker: oneSpeaker ? first.speakerLabel : nil, origin: "jot",
            scope: Source.Scope(session: first.sessionID), timestamp: ISO8601DateFormatter().string(from: start(first)),
            revision: Int(ContentHash.sha256(best.text).prefix(12), radix: 16) ?? 1, status: .current, text: best.text))
    }

    /// Add a matched quote without repeating a grouped speech turn or exceeding the prompt source bounds.
    public static func adding(_ match: Match?, to selected: [Source],
                              members: (Source) -> [Transcript] = { _ in [] }, limits: SelectionLimits = .window) -> [Source] {
        addition(match, to: selected, members: members, limits: limits).selected
    }

    public struct Addition: Sendable {
        public let selected: [Source]
        /// Selected speech replaced by the matching heard sentence because it shares backing rows.
        public let duplicateSpeechCount: Int
        /// Selected speech dropped to keep the final prompt inside its source and byte limits.
        public let overLimitSpeechCount: Int
    }

    /// The final prompt inputs and the two reasons an earlier selected speech source stopped being used.
    public static func addition(_ match: Match?, to selected: [Source],
                                members: (Source) -> [Transcript] = { _ in [] }, limits: SelectionLimits = .window) -> Addition {
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

/// The card's source line: whose words the suggestion came from, in plain terms.
public enum SuggestionAttribution {
    public static func line(plan: SuggestionPlan, selected: [Source], sessionTitle: String?) -> String {
        var parts: [String] = []
        if case .draft(let seed) = plan { parts.append(seed.isSelection ? "Your selection" : "Your notes") }
        if plan == .continuation { parts.append("Your text") }
        if selected.contains(where: { $0.kind == ScreenContext.kind }) { parts.append("text on screen") }
        if selected.contains(where: { $0.kind == HeardSpeech.kind }) { parts.append("what Jot heard") }
        if selected.contains(where: { $0.kind == AgentContext.kind }) { parts.append("your agent conversation") }
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "meeting ‘\($0)’" } ?? "recent speech")
        }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        return parts.joined(separator: " + ")
    }
}
