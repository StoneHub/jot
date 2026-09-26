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

/// The card's source line: whose words the suggestion came from, in plain terms.
public enum SuggestionAttribution {
    public static func line(plan: SuggestionPlan, selected: [Source], sessionTitle: String?) -> String {
        var parts: [String] = []
        if case .draft(let seed) = plan { parts.append(seed.isSelection ? "Your selection" : "Your notes") }
        if selected.contains(where: { $0.kind == ScreenContext.kind }) { parts.append("text on screen") }
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "meeting ‘\($0)’" } ?? "the latest meeting")
        }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        return parts.joined(separator: " + ")
    }
}
