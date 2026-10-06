import Foundation

/// One `transcripts.since` page. Pass `cursor` and `generation` back together. Apply `deleted` by id and replace `rows` by id; `hasMore` asks for the next page now, otherwise wait `pollAfterSeconds`.
public struct TranscriptChanges: Codable, Sendable, Equatable {
    /// How long a caught-up follower should wait before polling again. The server does not refuse faster polls; a caught-up poll costs one counter read.
    public static let caughtUpPollSeconds = 2.0
    public var rows: [TranscriptChange]
    public var cursor: Int64
    public var hasMore: Bool
    public var deleted: [TranscriptDeletion]
    /// The database identity, stable across reopen. Numeric cursors alone cannot detect every database rebuild.
    public var generation: String?
    /// The cursor or generation belongs to another store. Discard the follower's copy before applying this page.
    public var reset: Bool
    public var pollAfterSeconds: Double
    public init(rows: [TranscriptChange], cursor: Int64, hasMore: Bool, reset: Bool = false,
                deleted: [TranscriptDeletion] = [], generation: String? = nil) {
        self.rows = rows; self.cursor = cursor; self.hasMore = hasMore; self.reset = reset
        self.deleted = deleted
        self.generation = generation
        pollAfterSeconds = hasMore ? 0 : Self.caughtUpPollSeconds
    }

    private enum CodingKeys: String, CodingKey { case rows, cursor, hasMore, reset, pollAfterSeconds, deleted, generation }

    /// Older servers send neither tombstones nor a generation; their existing pages still decode.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rows = try values.decode([TranscriptChange].self, forKey: .rows)
        cursor = try values.decode(Int64.self, forKey: .cursor)
        hasMore = try values.decode(Bool.self, forKey: .hasMore)
        reset = try values.decode(Bool.self, forKey: .reset)
        pollAfterSeconds = try values.decode(Double.self, forKey: .pollAfterSeconds)
        deleted = try values.decodeIfPresent([TranscriptDeletion].self, forKey: .deleted) ?? []
        generation = try values.decodeIfPresent(String.self, forKey: .generation)
    }
}
