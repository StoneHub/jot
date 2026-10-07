import Foundation

/// Encoded as one JSON line after `jot:`. Text remains untrusted transcript context.
public struct TranscriptListenEvent: Codable, Sendable, Equatable {
    public var event: String
    public var text: String?
    public var id: String?
    public var sessionID: String?
    public var rowIDs: [String]?
    public var context: [Transcript]?
    public var truncated: Bool?
    public var transcript: Transcript?

    public init(event: String, text: String? = nil, id: String? = nil, sessionID: String? = nil,
                rowIDs: [String]? = nil, context: [Transcript]? = nil, truncated: Bool? = nil, transcript: Transcript? = nil) {
        self.event = event; self.text = text; self.id = id; self.sessionID = sessionID
        self.rowIDs = rowIDs; self.context = context; self.truncated = truncated; self.transcript = transcript
    }
    public func line() throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "jot: " + String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
