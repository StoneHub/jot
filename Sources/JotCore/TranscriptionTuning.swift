import Foundation

public struct TranscriptionTuning: Codable, Sendable, Equatable {
    public var speakerConfidence: Double = 0.65
    public var minimumSpeakerTurn: Double = 0.8
    public var paragraphPause: Double = 1.0
    public var hideFillerRows = true
    public init() {}
    public static var steady: Self {
        var value = Self(); value.speakerConfidence = 0.75; value.minimumSpeakerTurn = 1.2; value.paragraphPause = 1.5
        return value
    }
    public static var detailed: Self {
        var value = Self(); value.speakerConfidence = 0.5; value.minimumSpeakerTurn = 0.2; value.paragraphPause = 0.5; value.hideFillerRows = false
        return value
    }
    public var bounded: Self {
        var result = self
        result.speakerConfidence = speakerConfidence.isFinite ? min(0.9, max(0.45, speakerConfidence)) : 0.65
        result.minimumSpeakerTurn = minimumSpeakerTurn.isFinite ? min(2, max(0.2, minimumSpeakerTurn)) : 0.8
        result.paragraphPause = paragraphPause.isFinite ? min(2.5, max(0.3, paragraphPause)) : 1
        return result
    }
}

public struct AttributedWord: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let probabilities: [Float]
    public init(text: String, start: Double, end: Double, probabilities: [Float]) {
        self.text = text; self.start = start; self.end = end; self.probabilities = probabilities
    }
}
public struct SpeechTurn: Sendable {
    public var text: String
    public let start: Double
    public var end: Double
    public var speaker: String?
}

public enum TranscriptGrouping {
    public static func isFillerOnly(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        let fillers: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "hmm", "hm"]
        return !words.isEmpty && words.allSatisfy { fillers.contains(String($0)) }
    }

    /// Confirm a new speaker only after sustained evidence. Short replies can stay with
    /// the preceding speaker; this is an explicit user-adjustable stability tradeoff.
    public static func turns(_ words: [AttributedWord], tuning raw: TranscriptionTuning, continuing initialSpeaker: String? = nil) -> [SpeechTurn] {
        guard !words.isEmpty else { return [] }
        let tuning = raw.bounded
        var candidates: [String?] = words.map { word in
            let active = word.probabilities.prefix(4).enumerated().filter { Double($0.element) >= tuning.speakerConfidence }
            return active.count == 1 ? "speaker-\(active[0].offset + 1)" : (active.count > 1 ? "overlap" : nil)
        }
        // Seeded from the previous audio block so a sentence that spans a block boundary keeps its speaker.
        var stable: String? = initialSpeaker
        var runStart = 0
        while runStart < words.count {
            var runEnd = runStart + 1
            while runEnd < words.count && candidates[runEnd] == candidates[runStart]
                && words[runEnd].start - words[runEnd - 1].end < tuning.paragraphPause { runEnd += 1 }
            let duration = words[runEnd - 1].end - words[runStart].start
            let onlyFillers = isFillerOnly(words[runStart..<runEnd].map(\.text).joined(separator: " "))
            if runStart > 0 && words[runStart].start - words[runStart - 1].end >= tuning.paragraphPause { stable = nil }
            if duration >= tuning.minimumSpeakerTurn && !onlyFillers { stable = candidates[runStart] }
            for index in runStart..<runEnd { candidates[index] = stable }
            runStart = runEnd
        }
        // Fold a short leading hesitation into its first confirmed turn, not a separate row.
        if let first = candidates.firstIndex(where: { $0 != nil }), first > 0,
           words[first].start - words[0].start < tuning.minimumSpeakerTurn + tuning.paragraphPause {
            for index in 0..<first { candidates[index] = candidates[first] }
        }
        var result: [SpeechTurn] = []
        for (index, word) in words.enumerated() {
            if let last = result.last, last.speaker == candidates[index], word.start - last.end < tuning.paragraphPause {
                result[result.count - 1].text += " " + word.text
                result[result.count - 1].end = word.end
            } else { result.append(SpeechTurn(text: word.text, start: word.start, end: word.end, speaker: candidates[index])) }
        }
        return result
    }

    /// Export-time repair: an unattributed ambient row that picks up a speaker's unfinished sentence within `gap` seconds inherits that speaker. Stored rows are unchanged.
    public static func foldContinuations(_ source: [Transcript], gap: Double = 1.5) -> [Transcript] {
        var result = source.sorted { $0.startedAt.addingTimeInterval($0.startSeconds) < $1.startedAt.addingTimeInterval($1.startSeconds) }
        for index in result.indices.dropFirst() {
            let previous = result[index - 1]
            guard result[index].speakerID == nil, result[index].mode == "ambient", previous.mode == "ambient",
                  previous.sessionID == result[index].sessionID,
                  let speaker = previous.speakerID, speaker != "overlap",
                  result[index].startSeconds - previous.endSeconds < gap,
                  !endsSentence(previous.text) else { continue }
            result[index].speakerID = speaker
            result[index].speakerLabel = previous.speakerLabel
        }
        return result
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last(where: { !"\"')]".contains($0) }) else { return false }
        return ".!?".contains(last)
    }

    /// Presentation only: source rows and words remain in SQLite for inspection/export.
    public static func history(_ source: [Transcript], tuning: TranscriptionTuning) -> [Transcript] {
        let sorted = source.sorted { $0.startedAt.addingTimeInterval($0.startSeconds) < $1.startedAt.addingTimeInterval($1.startSeconds) }
        var result: [Transcript] = []
        for item in sorted {
            if tuning.hideFillerRows && isFillerOnly(item.text) { continue }
            if let previous = result.last, item.mode == "ambient", previous.mode == "ambient",
               item.sessionID == previous.sessionID, item.speakerID == previous.speakerID,
               item.speakerLabel == previous.speakerLabel,
               item.startSeconds >= previous.endSeconds,
               item.startSeconds - previous.endSeconds < tuning.bounded.paragraphPause {
                result[result.count - 1].text += " " + item.text
                result[result.count - 1].endSeconds = item.endSeconds
            } else { result.append(item) }
        }
        return result.reversed()
    }
}
