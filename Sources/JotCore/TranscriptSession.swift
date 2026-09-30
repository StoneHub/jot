import Foundation

public struct TranscriptSession: Codable, Sendable, Identifiable, Equatable {
    public let sessionID: String
    public let startedAt: Date
    public let lastTranscriptAt: Date
    public let transcriptCount: Int
    /// Set by meeting mode or a rename; nil for an untitled ambient session.
    public var title: String?
    public var id: String { sessionID }
    public var durationSeconds: Double { lastTranscriptAt.timeIntervalSince(startedAt) }
    public init(sessionID: String, startedAt: Date, lastTranscriptAt: Date, transcriptCount: Int, title: String? = nil) {
        self.sessionID = sessionID; self.startedAt = startedAt; self.lastTranscriptAt = lastTranscriptAt
        self.transcriptCount = transcriptCount; self.title = title
    }
}
