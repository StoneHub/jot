import Foundation

/// Bounds the audio waiting for recognition. A recognizer that stalls would otherwise keep every chunk the microphone
/// cuts, final ones included, for as long as listening runs. Once the queue holds the budget, further chunks are withheld
/// and counted as one gap, explicitly, until recognition has drained enough of the queue to take audio again.
public struct RecognitionBacklog: Equatable, Sendable {
    /// Ten minutes of audio is about 38 MB of samples: a slow recognizer may still catch up on it; a hung one cannot grow past it.
    public static let defaultBudgetSeconds = 600.0
    /// The queue must drain this far below the budget before audio is taken again, so a recognizer running just under
    /// real time records one gap at a time rather than one per chunk.
    public static let defaultHeadroomSeconds = 30.0

    public enum Decision: Equatable, Sendable {
        /// Queue the chunk; `endedGapSeconds` is the length of the gap it closes, when one was open.
        case queue(endedGapSeconds: Double?)
        /// Keep the chunk out of the queue; `began` marks the first chunk of a gap.
        case withhold(began: Bool)
    }

    public let budgetSeconds: Double
    public let headroomSeconds: Double
    /// Seconds of audio withheld since the queue filled; nil while audio is being queued.
    public private(set) var gapSeconds: Double?

    public init(budgetSeconds: Double = Self.defaultBudgetSeconds, headroomSeconds: Double = Self.defaultHeadroomSeconds) {
        self.budgetSeconds = max(0, budgetSeconds)
        self.headroomSeconds = min(max(0, headroomSeconds), self.budgetSeconds)
    }

    public var isFull: Bool { gapSeconds != nil }

    /// Decides for a chunk of `seconds` of audio when `queuedSeconds` are already waiting.
    public mutating func offer(seconds: Double, queuedSeconds: Double) -> Decision {
        let limit = isFull ? budgetSeconds - headroomSeconds : budgetSeconds
        if queuedSeconds + seconds <= limit {
            let ended = gapSeconds
            gapSeconds = nil
            return .queue(endedGapSeconds: ended)
        }
        let began = !isFull
        gapSeconds = (gapSeconds ?? 0) + seconds
        return .withhold(began: began)
    }

    /// Closes an open gap when its session ends, returning its length.
    public mutating func close() -> Double? {
        defer { gapSeconds = nil }
        return gapSeconds
    }
}
