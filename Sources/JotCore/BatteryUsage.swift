import Foundation

/// Sums net charge loss across observed battery-powered intervals.
/// This measures the whole computer, never energy attributable to one process.
public struct BatteryUsage: Codable {
    public private(set) var levelPercent: Double?
    public private(set) var powerSource = "Unavailable"
    public private(set) var usedPercentagePoints: Double = 0
    private var intervalStart: Double?
    private var completedLoss: Double = 0

    public init() {}

    public mutating func observe(level: Double?, onBattery: Bool?) {
        guard let level, level.isFinite, (0...100).contains(level), let onBattery else {
            completedLoss = usedPercentagePoints
            intervalStart = nil
            levelPercent = nil
            powerSource = "Unavailable"
            return
        }
        levelPercent = level
        powerSource = onBattery ? "Battery" : "Power adapter"
        if onBattery {
            if intervalStart == nil { intervalStart = level }
            usedPercentagePoints = completedLoss + max(0, intervalStart! - level)
        } else {
            completedLoss = usedPercentagePoints
            intervalStart = nil
        }
    }
}
