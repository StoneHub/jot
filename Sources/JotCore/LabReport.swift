import Foundation

/// A lab run's output files: every variant's rows as JSON, and one self-contained HTML page comparing the variants side by side.
public enum LabReport {
    public static func json(_ variants: [LabVariantResult]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(variants)
    }

    public static func html(audioName: String, variants: [LabVariantResult]) -> String {
        // Speaker columns appear only when the captions named speakers.
        let speakers = variants.contains { $0.score?.liveSpeakers != nil || $0.score?.passSpeakers != nil }
        var page = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Jot lab: \(escape(audioName))</title>
        <style>
        :root { color-scheme: light dark; --muted: #6b6b6b; --line: #d9d9d9; --changed: #2f6fdf; }
        @media (prefers-color-scheme: dark) { :root { --muted: #a0a0a0; --line: #3a3a3a; --changed: #7aa7ff; } }
        body { font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; }
        table { border-collapse: collapse; margin-bottom: 24px; }
        th, td { border-bottom: 1px solid var(--line); padding: 4px 10px; text-align: left; vertical-align: top; }
        .grid { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(280px, 1fr); gap: 16px; overflow-x: auto; }
        .row { border-bottom: 1px solid var(--line); padding: 4px 0; }
        .meta, .raw { color: var(--muted); font-size: 12px; }
        .changed .text { color: var(--changed); }
        code { font-size: 12px; }
        </style></head><body>
        <h1>Jot lab: \(escape(audioName))</h1>
        <table><tr><th>Variant</th><th>Settings</th><th>Run</th><th>Rows / paragraphs</th><th>Speakers (live / pass)</th><th>WER raw</th><th>WER cleaned</th>\(speakers ? "<th>Speaker words right</th><th>DER</th>" : "")<th>Cleanup phrases</th><th>Recognition</th><th>Speaker pass</th></tr>

        """
        for variant in variants {
            let settings = variant.settings.sorted { $0.key < $1.key }.map { "\($0.key) = \(describe($0.value))" }
            let live = Set(variant.rows.compactMap(\.liveSpeaker)).count
            let pass = Set(variant.rows.compactMap(\.passSpeaker)).count
            page += "<tr><td>\(escape(variant.name))</td><td><code>\(settings.isEmpty ? "current settings" : settings.map(escape).joined(separator: "<br>"))</code></td>"
            page += "<td>\(variant.recognitionRun)</td><td>\(variant.rows.count) / \(variant.paragraphs.count)</td><td>\(live) / \(pass)</td>"
            page += "<td>\(variant.score.map { rate($0.raw) } ?? "–")</td><td>\(variant.score.map { rate($0.cleaned) } ?? "–")</td>"
            if speakers { page += "<td>\(speakerLines(variant.score, accuracy))</td><td>\(speakerLines(variant.score, diarization))</td>" }
            let outcomes = variant.cleanupOutcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            page += "<td>\(outcomes.isEmpty ? "–" : escape(outcomes))</td>"
            page += String(format: "<td>%.1f s</td><td>%.1f s</td></tr>\n", variant.timings.recognitionSeconds, variant.timings.speakerPassSeconds)
        }
        page += "</table>\n"
        if speakers {
            page += String(format: """
                <p class="meta">Speaker words right: recognized words whose speaker matches the captions' after each speaker id is \
                paired with at most one caption voice. Words between cues are not scored; words in a row with no speaker count \
                as wrong. DER: diarization error rate over the stored rows, with a %.2f s collar each side of every cue boundary. \
                Time between rows counts as missed speech, and row time outside every cue as false alarm.</p>

                """, LabSpeakerScore.DiarizationError.collarSeconds / 2)
        }
        page += "<div class=\"grid\">\n"
        for variant in variants {
            page += "<section><h2>\(escape(variant.name))</h2>\n"
            let hasPass = variant.paragraphs.contains { $0.passSpeaker != nil }
            for row in variant.paragraphs {
                let speaker = (hasPass ? row.passSpeaker : row.liveSpeaker) ?? "unknown"
                let changed = row.cleanup == .changed
                page += "<div class=\"row\(changed ? " changed" : "")\"><div class=\"meta\">\(TranscriptExport.clock(row.start)) · \(escape(speaker))"
                if hasPass, row.liveSpeaker != row.passSpeaker { page += " (live \(escape(row.liveSpeaker ?? "unknown")))" }
                page += " · \(row.cleanup.rawValue)</div><div class=\"text\">\(escape(row.cleanedText ?? row.rawText))</div>"
                if changed || row.cleanup == .removed { page += "<div class=\"raw\">\(escape(row.rawText))</div>" }
                page += "</div>\n"
            }
            page += "</section>\n"
        }
        return page + "</div></body></html>\n"
    }

    private static func rate(_ score: WordErrorRate.Score) -> String {
        String(format: "%.1f%% <span class=\"meta\">(S %d, D %d, I %d of %d)</span>", score.rate * 100,
            score.substitutions, score.deletions, score.insertions, score.referenceWords)
    }

    /// One line each for the live and pass speakers, or a dash when neither has the measure.
    private static func speakerLines(_ score: LabScore?, _ line: (LabSpeakerScore) -> String?) -> String {
        let lines = [("live", score?.liveSpeakers), ("pass", score?.passSpeakers)].compactMap { name, speakers in
            speakers.flatMap(line).map { "\(name) \($0)" }
        }
        return lines.isEmpty ? "–" : lines.joined(separator: "<br>")
    }

    private static func accuracy(_ score: LabSpeakerScore) -> String? {
        String(format: "%.1f%% <span class=\"meta\">(%d of %d words, %d unattributed)</span>", score.accuracy * 100,
            score.correct, score.words, score.unattributed)
    }

    private static func diarization(_ score: LabSpeakerScore) -> String? {
        guard let error = score.diarizationError, error.speechSeconds > 0 else { return nil }
        return String(format: "%.1f%% <span class=\"meta\">(missed %.1f%%, false alarm %.1f%%, confusion %.1f%%)</span>", error.rate * 100,
            error.missedSeconds / error.speechSeconds * 100, error.falseAlarmSeconds / error.speechSeconds * 100,
            error.confusionSeconds / error.speechSeconds * 100)
    }

    private static func describe(_ value: LabVariant.Value) -> String {
        switch value {
        case .bool(let value): String(value)
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .text(let value): "\"\(value)\""
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
