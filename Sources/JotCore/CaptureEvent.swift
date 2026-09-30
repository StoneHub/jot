import Foundation

/// Capture lifecycle metadata only. Callers must not put transcript text or audio in detail.
public struct CaptureEvent: Codable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var timestamp: Date
    public var kind: String
    public var detail: String
    public var durationSeconds: Double?

    public init(id: String = UUID().uuidString, sessionID: String, timestamp: Date = Date(),
                kind: String, detail: String, durationSeconds: Double? = nil) {
        self.id = id; self.sessionID = sessionID; self.timestamp = timestamp
        self.kind = kind; self.detail = detail; self.durationSeconds = durationSeconds
    }
}
