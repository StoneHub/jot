import Foundation

/// Durable delivery state for one held-dictation attempt. Audio is never stored here;
/// text is copied from the continuously saved recognition timeline.
public struct DictationAttempt: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case capturing
        case recognizing
        case ready
        case deliveryFailed
        case deliveryUnverified
        case delivered
        case discarded

        public var isRecoverable: Bool {
            switch self {
            case .capturing, .recognizing, .ready, .deliveryFailed, .deliveryUnverified: true
            default: false
            }
        }
    }

    public var id: String
    public var sessionID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var text: String
    public var state: State
    /// True when some audio in this attempt could not be verified as recognized.
    /// The retained text may still be explicitly recovered, but must be presented as partial.
    public var hasGap: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, sessionID: String, startedAt: Date,
                endedAt: Date? = nil, text: String = "", state: State = .capturing,
                hasGap: Bool = false,
                updatedAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
        self.state = state
        self.hasGap = hasGap
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, startedAt, endedAt, text, state, hasGap, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        text = try values.decode(String.self, forKey: .text)
        state = try values.decode(State.self, forKey: .state)
        hasGap = try values.decodeIfPresent(Bool.self, forKey: .hasGap) ?? false
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encode(text, forKey: .text)
        try values.encode(state, forKey: .state)
        try values.encode(hasGap, forKey: .hasGap)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}
