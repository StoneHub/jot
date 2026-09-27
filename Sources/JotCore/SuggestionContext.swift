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

/// The card's source line: whose words the suggestion came from, in plain terms.
public enum SuggestionAttribution {
    public static func line(plan: SuggestionPlan, selected: [Source], sessionTitle: String?) -> String {
        var parts: [String] = []
        if case .draft(let seed) = plan { parts.append(seed.isSelection ? "Your selection" : "Your notes") }
        if plan == .continuation { parts.append("Your text") }
        if selected.contains(where: { $0.kind == ScreenContext.kind }) { parts.append("text on screen") }
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
