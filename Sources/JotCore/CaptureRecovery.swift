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

public struct RecoverySelection: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case failedAttempt(String), recentSpeech }
    public let text: String
    public let source: Source
    public init(text: String, source: Source) { self.text = text; self.source = source }
}

/// Pure decision seam used by both the service and tests. A retained held attempt
/// always wins over the time-window fallback, including one interrupted by force quit.
public enum DictationRecovery {
    public static func select(attempt: DictationAttempt?, recentSpeech: String) -> RecoverySelection? {
        if let attempt, attempt.state.isRecoverable {
            let text = attempt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return RecoverySelection(text: text, source: .failedAttempt(attempt.id)) }
        }
        let text = recentSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : RecoverySelection(text: text, source: .recentSpeech)
    }
}

/// Bounded recognition chunks keep capture latency independent of how long Jot has
/// been listening. A sufficiently long silence may close a shorter chunk.
public struct CaptureChunkScheduler: Equatable, Sendable {
    public let maximumSamples: Int
    public let minimumSamples: Int
    public let silenceSamples: Int

    public init(sampleRate: Int = 16_000, maximumSeconds: Double = 3,
                minimumSeconds: Double = 0.2, silenceSeconds: Double = 0.7) {
        maximumSamples = max(1, Int((Double(sampleRate) * maximumSeconds).rounded()))
        minimumSamples = max(1, Int((Double(sampleRate) * minimumSeconds).rounded()))
        silenceSamples = max(1, Int((Double(sampleRate) * silenceSeconds).rounded()))
    }

    public func shouldFlush(bufferedSamples: Int, consecutiveSilentSamples: Int) -> Bool {
        bufferedSamples >= maximumSamples ||
            (bufferedSamples >= minimumSamples && consecutiveSilentSamples >= silenceSamples)
    }

    /// Splits an overdue buffer without dropping the tail. The caller can enqueue
    /// every complete chunk and keep the remainder for the next microphone drain.
    public func split(_ samples: [Float]) -> (chunks: [[Float]], remainder: [Float]) {
        guard samples.count >= maximumSamples else { return ([], samples) }
        var chunks: [[Float]] = []
        var start = 0
        while samples.count - start >= maximumSamples {
            chunks.append(Array(samples[start..<(start + maximumSamples)]))
            start += maximumSamples
        }
        return (chunks, Array(samples[start...]))
    }
}
