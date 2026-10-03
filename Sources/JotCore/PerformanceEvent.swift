import Foundation

public struct PerformanceEvent: Codable, Sendable {
    public let elapsedSeconds: Double
    public let kind: PerformanceEventKind
    public let footprintMiB: Double?
}
