import Foundation

public struct PerformanceReport: Codable, Sendable {
    public enum Build: String, Codable, Sendable { case debug, release, unspecified }
    public let build: Build
    public let schemaVersion: Int
    public let sampleIntervalSeconds: Double
    public let sampleCapacity: Int
    public let eventCapacity: Int
    public let jobCapacity: Int
    public let startup: PerformanceSample?
    public let current: PerformanceSample?
    public let sampledPeakFootprintMiB: Double?
    public let samples: [PerformanceSample]
    public let events: [PerformanceEvent]
    public let jobs: [PerformanceJob]
    /// Release to text in the field, over dictations that were inserted.
    public let dictationLatency: LatencySummary
    /// `dictationLatency` split by whether dictation cleanup ran.
    public let dictationLatencyWithCleanup: LatencySummary
    public let dictationLatencyWithoutCleanup: LatencySummary
    /// Time spent in dictation cleanup, over every dictation where it ran.
    public let dictationCleanupLatency: LatencySummary
    public let inferenceLatency: LatencySummary
}
