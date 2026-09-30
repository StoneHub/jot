import Foundation

/// One row from the change feed: the row as `transcripts.recent` returns it, plus the change sequence that delivered it. Encodes flat, so a reader sees the transcript's own keys and `sequence`.
public struct TranscriptChange: Codable, Sendable, Equatable {
    public var transcript: Transcript
    public var sequence: Int64
    public init(_ transcript: Transcript, sequence: Int64) { self.transcript = transcript; self.sequence = sequence }

    private enum Keys: String, CodingKey { case sequence }
    public init(from decoder: Decoder) throws {
        transcript = try Transcript(from: decoder)
        sequence = try decoder.container(keyedBy: Keys.self).decode(Int64.self, forKey: .sequence)
    }
    public func encode(to encoder: Encoder) throws {
        try transcript.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(sequence, forKey: .sequence)
    }
}
