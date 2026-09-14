import Foundation

/// Generation checks prevent work that started before Pause from reactivating capture.
public struct ServiceLifecycle: Sendable {
    public enum Phase: String, Codable, Sendable { case paused, starting, ready, pausing, failed }
    public private(set) var phase: Phase = .paused
    public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func beginStart() -> UInt64? {
        guard phase == .paused || phase == .failed else { return nil }
        generation &+= 1; phase = .starting
        return generation
    }
    @discardableResult public mutating func finishStart(_ token: UInt64, succeeded: Bool) -> Bool {
        guard token == generation, phase == .starting else { return false }
        phase = succeeded ? .ready : .failed
        return true
    }
    public mutating func beginPause() -> UInt64? {
        guard phase != .paused, phase != .pausing else { return nil }
        generation &+= 1; phase = .pausing
        return generation
    }
    @discardableResult public mutating func finishPause(_ token: UInt64) -> Bool {
        guard token == generation, phase == .pausing else { return false }
        phase = .paused; return true
    }
    public func acceptsWork(_ token: UInt64) -> Bool { phase == .ready && token == generation }
}

/// What a pause leaves for Resume. Sleep, an input change, and stalled input pause automatically and keep the selection; the Pause button clears it and ends a meeting.
public struct PauseOutcome: Equatable, Sendable {
    public let ambientRequested: Bool
    public let meetingTitle: String?
    /// True when the Pause button ended a running meeting, so the notice can say where its transcript went.
    public let endedMeeting: Bool
    public init(automatic: Bool, ambientRequested: Bool, meetingTitle: String?) {
        self.ambientRequested = automatic && ambientRequested
        self.meetingTitle = automatic ? meetingTitle : nil
        endedMeeting = !automatic && meetingTitle != nil
    }
}
