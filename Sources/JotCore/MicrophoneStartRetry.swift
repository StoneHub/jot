import Foundation

/// The input device is often not back for a few seconds after wake or a device change, so a failed microphone start is retried with growing gaps for about half a minute.
public struct MicrophoneStartRetry: Equatable, Sendable {
    public let delays: [TimeInterval]
    public init(delays: [TimeInterval] = [1, 2, 4, 8, 15]) { self.delays = delays }
    /// Seconds to wait before the next try, or nil when the failed attempt was the last one. Attempts count from 1.
    public func delay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
    public var attempts: Int { delays.count + 1 }
}
