/// A removed row in `transcripts.since`. Contains identity and ordering only; deleted text is never retained.
public struct TranscriptDeletion: Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String
    public var sequence: Int64

    public init(id: String, sessionID: String, sequence: Int64) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
    }
}
