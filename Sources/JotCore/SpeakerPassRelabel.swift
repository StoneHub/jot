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
}
