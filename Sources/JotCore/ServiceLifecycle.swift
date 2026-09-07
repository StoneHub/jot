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
