import Foundation

public struct Transcript: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sessionID: String
    public var startedAt: Date
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var speakerID: String?
    public var mode: String
    public var speakerLabel: String?

    public init(id: String = UUID().uuidString, sessionID: String, startedAt: Date,
                startSeconds: Double, endSeconds: Double, text: String,
                speakerID: String? = nil, mode: String, speakerLabel: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.startedAt = startedAt
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.text = text
        self.speakerID = speakerID; self.mode = mode; self.speakerLabel = speakerLabel
    }
}
