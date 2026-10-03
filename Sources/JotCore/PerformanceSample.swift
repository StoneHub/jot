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
