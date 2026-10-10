import Foundation

public struct PerformanceDiagnostics: Sendable {
    public static let sampleInterval: Double = 60
    public static let sampleCapacity = 1440
    public static let eventCapacity = 256
    public static let jobCapacity = 200
    private var startup: PerformanceSample?
    private var current: PerformanceSample?
    private var peak: Double?
    private var samples: [PerformanceSample] = []
    /// CPU seconds reported since the last kept sample, by samples that were not kept.
    private var cpuSecondsSinceKept = 0.0
    private var events: [PerformanceEvent] = []
    private var jobs: [PerformanceJob] = []
    private let build: PerformanceReport.Build
    public init(build: PerformanceReport.Build = .unspecified) { self.build = build }

    /// Call with existing resource samples. Failed resource reads must not be submitted.
    /// Each sample's CPU covers the time since the previous sample observed; a kept sample's CPU is rewritten to cover the time since the previous kept sample.
    public mutating func observe(_ sample: PerformanceSample) {
        guard [sample.elapsedSeconds, sample.footprintMiB, sample.residentMiB, sample.cpuPercent].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        if let current, sample.elapsedSeconds < current.elapsedSeconds { return }
        if let current { cpuSecondsSinceKept += sample.cpuPercent / 100 * (sample.elapsedSeconds - current.elapsedSeconds) }
        if startup == nil { startup = sample }
        current = sample
        peak = max(peak ?? 0, sample.footprintMiB)
        let interval = samples.last.map { sample.elapsedSeconds - $0.elapsedSeconds }
        if interval.map({ $0 >= Self.sampleInterval }) ?? true {
            var kept = sample
            if let interval { kept.cpuPercent = cpuSecondsSinceKept / interval * 100 }
            cpuSecondsSinceKept = 0
            samples.append(kept)
            if samples.count > Self.sampleCapacity { samples.removeFirst(samples.count - Self.sampleCapacity) }
        }
    }
    public mutating func mark(_ kind: PerformanceEventKind, at seconds: Double) {
        events.append(.init(elapsedSeconds: seconds, kind: kind, footprintMiB: current?.footprintMiB))
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
    }
    /// Continuous recognition records a job every few seconds, so dropping the oldest job would push out held dictations within minutes. Each mode keeps at least half the jobs before its own oldest goes.
    public mutating func record(_ job: PerformanceJob) {
        jobs.append(job)
        guard jobs.count > Self.jobCapacity else { return }
        let mode: PerformanceJob.Mode = jobs.lazy.filter { $0.mode == .dictation }.count > Self.jobCapacity / 2 ? .dictation : .ambient
        jobs.remove(at: jobs.firstIndex { $0.mode == mode } ?? 0)
    }
    public var report: PerformanceReport {
        let successful = jobs.filter { $0.outcome == .completed || $0.outcome == .deliveryUnverified || $0.outcome == .noSpeech || $0.outcome == .fillerOnly }
        let dictations = jobs.filter { $0.mode == .dictation }
        let inserted = dictations.filter { $0.outcome == .completed || $0.outcome == .deliveryUnverified }
        return .init(build: build, schemaVersion: 1, sampleIntervalSeconds: Self.sampleInterval,
                     sampleCapacity: Self.sampleCapacity, eventCapacity: Self.eventCapacity, jobCapacity: Self.jobCapacity,
                     startup: startup, current: current, sampledPeakFootprintMiB: peak, samples: samples, events: events, jobs: jobs,
                     dictationLatency: .init(inserted.map(\.completionSeconds)),
                     dictationLatencyWithCleanup: .init(inserted.filter { $0.cleanupOutcome != nil }.map(\.completionSeconds)),
                     dictationLatencyWithoutCleanup: .init(inserted.filter { $0.cleanupOutcome == nil }.map(\.completionSeconds)),
                     dictationCleanupLatency: .init(dictations.filter { $0.cleanupOutcome != nil }.compactMap(\.cleanupSeconds)),
                     inferenceLatency: .init(successful.compactMap(\.inferenceSeconds)))
    }
    public func export() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
