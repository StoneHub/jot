import Foundation

/// Renders one session as a readable document. Rows are folded and merged for reading; SQLite keeps the originals.
public enum TranscriptExport {
    /// Consecutive rows from the same speaker join into one paragraph unless the pause between them reaches `mergeWithin` seconds.
    public static func paragraphs(_ rows: [Transcript], mergeWithin: Double = 8) -> [Transcript] {
        var result: [Transcript] = []
        for row in rows {
            if let previous = result.last, previous.speakerID == row.speakerID, previous.speakerLabel == row.speakerLabel,
               previous.sessionID == row.sessionID, row.startSeconds - previous.endSeconds < mergeWithin {
                result[result.count - 1].text += " " + row.text.trimmingCharacters(in: .whitespaces)
                result[result.count - 1].endSeconds = max(previous.endSeconds, row.endSeconds)
            } else { result.append(row) }
        }
        return result
    }

    public static func markdown(session: TranscriptSession, rows: [Transcript]) -> String {
        let folded = TranscriptGrouping.foldContinuations(rows)
        let merged = paragraphs(folded)
        let duration = rows.map(\.endSeconds).max() ?? 0
        var lines = ["# \(session.title ?? "Session") \(timestamp(session.startedAt))", "",
                     "Session \(session.sessionID). \(rows.count) segments, \(clock(duration)) of audio, ending \(timestamp(session.lastTranscriptAt)).",
                     "Speakers without a name are Jot's automatic groupings. Timestamps are offsets from session start.", ""]
        for row in merged {
            lines.append("**[\(clock(row.startSeconds))] \(speakerName(row)):** \(row.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Filesystem-safe name such as "2026-09-08 11-41 Webex review.md".
    public static func fileName(for session: TranscriptSession) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = formatter.string(from: session.startedAt)
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let title = (session.title ?? "").components(separatedBy: unsafe).joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (title.isEmpty ? "\(stamp) Session" : "\(stamp) \(title.prefix(80))") + ".md"
    }

    public static func speakerName(_ row: Transcript) -> String {
        if let label = row.speakerLabel, !label.isEmpty { return label }
        switch row.speakerID {
        case nil: return "Unattributed"
        case "overlap"?: return "Overlap"
        case let id?: return id.replacingOccurrences(of: "speaker-", with: "Speaker ")
        }
    }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
}
