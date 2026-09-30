import Foundation

/// One `transcripts.since` page. Pass `cursor` back to read what changed after it; `hasMore` asks for the next page now, otherwise wait `pollAfterSeconds`.
public struct TranscriptChanges: Codable, Sendable, Equatable {
    /// How long a caught-up follower should wait before polling again. The server does not refuse faster polls; a caught-up poll costs one counter read.
    public static let caughtUpPollSeconds = 2.0
    public var rows: [TranscriptChange]
    public var cursor: Int64
    public var hasMore: Bool
    /// The cursor was ahead of this store, as after its database was recreated, so the page starts from the beginning.
    public var reset: Bool
    public var pollAfterSeconds: Double
    public init(rows: [TranscriptChange], cursor: Int64, hasMore: Bool, reset: Bool = false) {
        self.rows = rows; self.cursor = cursor; self.hasMore = hasMore; self.reset = reset
        pollAfterSeconds = hasMore ? 0 : Self.caughtUpPollSeconds
    }
}
