import Foundation

/// Deliberately numeric/enumerated: diagnostic exports cannot contain captured content.
public struct PerformanceSample: Codable, Equatable, Sendable {
    public var elapsedSeconds: Double
    public var footprintMiB: Double
    public var residentMiB: Double
    public var cpuPercent: Double
    public var droppedAudioSeconds: Double
    public var bufferedAudioSeconds: Double
    public var queuedAudioSeconds: Double
    public var loadedHistoryRows: Int
    public var modelsReady: Bool
    public var ambientEnabled: Bool
    public var dictationActive: Bool
    public var inferenceRunning: Bool
    public init(elapsedSeconds: Double, footprintMiB: Double, residentMiB: Double, cpuPercent: Double,
                droppedAudioSeconds: Double = 0, bufferedAudioSeconds: Double = 0, queuedAudioSeconds: Double = 0, loadedHistoryRows: Int = 0,
                modelsReady: Bool = false, ambientEnabled: Bool = false, dictationActive: Bool = false, inferenceRunning: Bool = false) {
        self.elapsedSeconds = elapsedSeconds; self.footprintMiB = footprintMiB; self.residentMiB = residentMiB
        self.droppedAudioSeconds = droppedAudioSeconds
        self.cpuPercent = cpuPercent; self.bufferedAudioSeconds = bufferedAudioSeconds; self.queuedAudioSeconds = queuedAudioSeconds
        self.loadedHistoryRows = loadedHistoryRows; self.modelsReady = modelsReady; self.ambientEnabled = ambientEnabled
        self.dictationActive = dictationActive; self.inferenceRunning = inferenceRunning
    }
}

public enum PerformanceEventKind: String, Codable, Sendable {
    case launch, modelLoadStarted, modelsReady, modelsUnloaded, pause, resume
    case dictationStarted, dictationReleased, dictationCancelled, ambientStarted, ambientStopped
    case sleep, deviceChange, audioGap, processingFailed
}
public struct PerformanceEvent: Codable, Sendable {
    public let elapsedSeconds: Double
    public let kind: PerformanceEventKind
    public let footprintMiB: Double?
}
public struct PerformanceJob: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case dictation, ambient }
    public enum Outcome: String, Codable, Sendable { case completed, noSpeech, cancelled, failed, deliveryUnverified }
    public var elapsedSeconds: Double
    public var mode: Mode
    public var outcome: Outcome
    public var audioSeconds: Double
    public var queueWaitSeconds: Double
    public var inferenceSeconds: Double?
    /// From submission (Fn release for dictation) to completion, including delivery.
    public var completionSeconds: Double
    public init(elapsedSeconds: Double, mode: Mode, outcome: Outcome, audioSeconds: Double, queueWaitSeconds: Double,
                inferenceSeconds: Double?, completionSeconds: Double) {
        self.elapsedSeconds = elapsedSeconds; self.mode = mode; self.outcome = outcome; self.audioSeconds = audioSeconds
        self.queueWaitSeconds = queueWaitSeconds; self.inferenceSeconds = inferenceSeconds; self.completionSeconds = completionSeconds
    }
}
public struct LatencySummary: Codable, Sendable {
    public let count: Int
    public let medianSeconds: Double?
    public let p95Seconds: Double?
    public init(_ values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = sorted.count
        guard !sorted.isEmpty else { medianSeconds = nil; p95Seconds = nil; return }
        let middle = sorted.count / 2
        medianSeconds = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        p95Seconds = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
}

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
    public let dictationLatency: LatencySummary
    public let inferenceLatency: LatencySummary
}

public struct PerformanceDiagnostics: Sendable {
    public static let sampleInterval: Double = 30
    public static let sampleCapacity = 2880
    public static let eventCapacity = 256
    public static let jobCapacity = 200
    private var startup: PerformanceSample?
    private var current: PerformanceSample?
    private var peak: Double?
    private var samples: [PerformanceSample] = []
    private var events: [PerformanceEvent] = []
    private var jobs: [PerformanceJob] = []
    private let build: PerformanceReport.Build
    public init(build: PerformanceReport.Build = .unspecified) { self.build = build }

    /// Call with existing resource samples. Failed resource reads must not be submitted.
    public mutating func observe(_ sample: PerformanceSample) {
        guard [sample.elapsedSeconds, sample.footprintMiB, sample.residentMiB, sample.cpuPercent].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        if let current, sample.elapsedSeconds < current.elapsedSeconds { return }
        if startup == nil { startup = sample }
        current = sample
        peak = max(peak ?? 0, sample.footprintMiB)
        if samples.last.map({ sample.elapsedSeconds - $0.elapsedSeconds >= Self.sampleInterval }) ?? true {
            samples.append(sample)
            if samples.count > Self.sampleCapacity { samples.removeFirst(samples.count - Self.sampleCapacity) }
        }
    }
    public mutating func mark(_ kind: PerformanceEventKind, at seconds: Double) {
        events.append(.init(elapsedSeconds: seconds, kind: kind, footprintMiB: current?.footprintMiB))
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
    }
    public mutating func record(_ job: PerformanceJob) {
        jobs.append(job)
        if jobs.count > Self.jobCapacity { jobs.removeFirst(jobs.count - Self.jobCapacity) }
    }
    public var report: PerformanceReport {
        let successful = jobs.filter { $0.outcome == .completed || $0.outcome == .deliveryUnverified || $0.outcome == .noSpeech }
        return .init(build: build, schemaVersion: 1, sampleIntervalSeconds: Self.sampleInterval,
                     sampleCapacity: Self.sampleCapacity, eventCapacity: Self.eventCapacity, jobCapacity: Self.jobCapacity,
                     startup: startup, current: current, sampledPeakFootprintMiB: peak, samples: samples, events: events, jobs: jobs,
                     dictationLatency: .init(successful.filter { $0.mode == .dictation }.map(\.completionSeconds)),
                     inferenceLatency: .init(successful.compactMap(\.inferenceSeconds)))
    }
    public func export() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
