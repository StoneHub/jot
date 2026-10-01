import CoreGraphics
import Foundation

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

    public static func source(_ excerpt: String, at date: Date) -> SuggestionSource {
        SuggestionSource(id: "screen", kind: kind, role: "unknown", origin: "accessibility", scope: SuggestionSource.Scope(),
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
