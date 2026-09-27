import Foundation

/// Maps a session's stored words onto the offline speaker pass. Pure: words and segments in, one speaker per word out.
public enum SpeakerPassRelabel {
    public typealias Segment = (speaker: String, start: Double, end: Double)

    /// Pass ids ("S1", "S3") become Jot's "speaker-1", "speaker-2" in order of first speech, so the numbering is the same every time the session is regrouped from the pass.
    public static func speakerIDs(segments: [Segment]) -> [String: String] {
        var result: [String: String] = [:]
        for segment in segments.sorted(by: { ($0.start, $0.end, $0.speaker) < ($1.start, $1.end, $1.speaker) }) where result[segment.speaker] == nil {
            result[segment.speaker] = "speaker-\(result.count + 1)"
        }
        return result
    }

    /// The same result with every speaker id renumbered by speakerIDs, so what is stored matches the transcript rows.
    public static func renumbered(_ result: SpeakerPassResult) -> SpeakerPassResult {
        let ids = speakerIDs(segments: result.segments)
        var renamed = result
        renamed.segments = result.segments.map { (ids[$0.speaker] ?? $0.speaker, $0.start, $0.end) }
        renamed.speakers = Dictionary(uniqueKeysWithValues: result.speakers.map { (ids[$0.key] ?? $0.key, $0.value) })
        return renamed
    }

    /// One speaker per word. Each word takes the pass speaker around its midpoint; a word no segment covers keeps the previous speaker within the paragraph pause and is otherwise unattributed. The pass decides speakers outright: no minimum turn or confirmation applies.
    public static func speakers(words: [StoredWord], segments: [Segment], tuning raw: TranscriptionTuning) -> [String?] {
        let tuning = raw.bounded
        let ids = speakerIDs(segments: segments)
        let spans = words.map { (start: $0.startSeconds, end: $0.endSeconds) }
        let assigned = SpeakerAssignment.assign(words: spans, segments: segments)
        var result = assigned.map { $0.flatMap { ids[$0] } }
        for index in result.indices.dropFirst() where result[index] == nil && words[index].startSeconds - words[index - 1].endSeconds < tuning.paragraphPause {
            result[index] = result[index - 1]
        }
        return result
    }

    /// Names given while a session's rows carried live speaker ids, moved onto the pass speakers those voices became. Live and pass ids are numbered separately, so the live "speaker-2" can be another voice in the pass. `before` is each row's live speaker by row id, and `after` the pass speaker of each word. A pass speaker takes a name only when rows under that name gave it more time than any other source: another name, a live speaker nobody named, or rows with no speaker. Live speakers given the same name count as one, and each name goes to one pass speaker, the one it gave the most time.
    public static func carriedLabels(_ labels: [String: String], words: [StoredWord], before: [String: String], after: [String?]) -> [String: String] {
        var seconds: [String: [String: Double]] = [:]
        var names: [String: String] = [:]
        for (word, new) in zip(words, after) {
            guard let new else { continue }
            let source: String
            if let old = before[word.transcriptID], let name = labels[old] {
                source = "name:" + PeopleMatcher.nameKey(name)
                if names[source] == nil { names[source] = name }
            } else {
                source = "live:" + (before[word.transcriptID] ?? "")
            }
            seconds[new, default: [:]][source, default: 0] += max(word.endSeconds - word.startSeconds, 0.01)
        }
        let claims = seconds.compactMap { new, bySource -> (new: String, source: String, seconds: Double)? in
            guard let top = bySource.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), names[top.key] != nil else { return nil }
            return (new, top.key, top.value)
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.new < $1.new }
        var result: [String: String] = [:]
        var placed = Set<String>()
        for claim in claims where !placed.contains(claim.source) {
            result[claim.new] = names[claim.source]
            placed.insert(claim.source)
        }
        return result
    }
}
