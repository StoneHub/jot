import Foundation

/// Caption files a lab run is scored against: SubRip (.srt) and WebVTT (.vtt). The cue text and times are read, and the
/// speaker a WebVTT voice tag (`<v Name>`) names, in either format; styling, positions and notes are dropped.
public enum LabCaptions {
    public struct Cue: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
        /// The voice the cue's tags name. Nil when it has no voice tag, or names two voices whose words can't be placed in time.
        public var speaker: String?
    }

    public static func parse(_ contents: String) throws -> [Cue] {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [Cue] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard line.contains("-->") else { continue }
            let sides = line.components(separatedBy: "-->")
            // A WebVTT timing line can carry cue settings after the end time.
            guard sides.count == 2, let start = seconds(sides[0]),
                  let end = seconds(sides[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            var text: [String] = []
            var voices: Set<String> = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                voices.formUnion(self.voices(lines[index]))
                text.append(clean(lines[index]))
                index += 1
            }
            let joined = text.filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { cues.append(Cue(start: start, end: end, text: joined, speaker: voices.count == 1 ? voices.first : nil)) }
        }
        guard !cues.isEmpty else { throw LabError.invalid("The caption file has no timed cues; use SubRip (.srt) or WebVTT (.vtt).") }
        return cues
    }

    /// `00:01:02,345`, `01:02.345` or `1:02:03.4`.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The names a line's voice tags give: `<v Kim>`, or `<v.loud Kim>` with a class.
    private static func voices(_ line: String) -> [String] {
        line.matches(of: #/<v(?:\.[^\s>]*)?\s+([^>]+)>/#).map { clean(String($0.output.1)) }.filter { !$0.isEmpty }
    }
}
