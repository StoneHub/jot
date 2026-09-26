import Foundation

/// Renders one session as a readable document. Rows are folded and merged for reading; SQLite keeps the originals.
public enum TranscriptExport {
    /// Consecutive rows from the same speaker join into one paragraph unless the pause between them reaches `mergeWithin` seconds.
    public static func paragraphs(_ rows: [Transcript], mergeWithin: Double = 1.5) -> [Transcript] {
        var result: [Transcript] = []
        for row in rows {
            if let last = result.indices.last, canMerge(row, into: result[last], within: mergeWithin) {
                merge(row, into: &result[last])
            } else { result.append(row) }
        }
        return result
    }

    /// One row of paragraphs: whether the row joins the paragraph before it rather than starting a new one.
    public static func canMerge(_ row: Transcript, into paragraph: Transcript, within mergeWithin: Double) -> Bool {
        paragraph.speakerID == row.speakerID && paragraph.speakerLabel == row.speakerLabel
            && paragraph.sessionID == row.sessionID && paragraph.mode == row.mode
            && row.startSeconds - paragraph.endSeconds >= -0.1
            && row.startSeconds - paragraph.endSeconds < mergeWithin
    }

    /// Joins the row's text and end onto the paragraph. The text is added in place, so a long paragraph is built in time proportional to its length rather than its square.
    public static func merge(_ row: Transcript, into paragraph: inout Transcript) {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty && !paragraph.text.isEmpty {
            paragraph.text += " "
        }
        paragraph.text += text
        paragraph.endSeconds = max(paragraph.endSeconds, row.endSeconds)
    }

    /// The paragraphs Sessions shows and Markdown exports: continuations folded and rows merged at the tuning's paragraph pause.
    public static func readingParagraphs(_ rows: [Transcript], tuning: TranscriptionTuning) -> [Transcript] {
        let pause = tuning.bounded.paragraphPause
        return paragraphs(TranscriptGrouping.foldContinuations(rows, gap: pause), mergeWithin: pause)
    }

    public static func markdown(session: TranscriptSession, rows: [Transcript], tuning: TranscriptionTuning = TranscriptionTuning()) -> String {
        let merged = readingParagraphs(rows, tuning: tuning)
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
        let stamp = fileStamp.string(from: session.startedAt)
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let title = (session.title ?? "").components(separatedBy: unsafe).joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (title.isEmpty ? "\(stamp) Session" : "\(stamp) \(title.prefix(80))") + ".md"
    }

    /// Exclusive creation preserves earlier exports, including files edited outside Jot.
    public static func write(session: TranscriptSession, rows: [Transcript], directory: URL, tuning: TranscriptionTuning = TranscriptionTuning()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: fileName(for: session)).deletingPathExtension().lastPathComponent
        let data = Data(markdown(session: session, rows: rows, tuning: tuning).utf8)
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : " (\(attempt))"
            let url = directory.appendingPathComponent("\(base)\(suffix).md")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                attempt += 1
            }
        }
    }

    public static func speakerName(_ row: Transcript) -> String {
        if let label = row.speakerLabel, !label.isEmpty { return label }
        switch row.speakerID {
        case nil: return "Unattributed"
        case "overlap"?: return "Overlap"
        case let id?: return id.replacingOccurrences(of: "speaker-", with: "Speaker ")
        }
    }

    /// History wording for a row with no speaker; exports keep "Unattributed" so saved Markdown does not change.
    public static func historyName(_ row: Transcript) -> String {
        guard row.speakerID == nil, (row.speakerLabel ?? "").isEmpty else { return speakerName(row) }
        return row.mode == "dictation" ? "Dictation" : "Unknown speaker"
    }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    // Shared formatters: DateFormatter has been thread-safe since macOS 10.9, and the callers are the main actor and the CLI anyway.
    private static let fileStamp: DateFormatter = { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH-mm"; return formatter }()
    private static let headerStamp: DateFormatter = { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"; return formatter }()

    private static func timestamp(_ date: Date) -> String { headerStamp.string(from: date) }
}
