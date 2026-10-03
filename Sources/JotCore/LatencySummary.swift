import Foundation

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
