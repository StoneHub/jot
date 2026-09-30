import Foundation

public struct StoreMetrics: Codable, Sendable {
    public let transcriptCount: Int
    public let sessionCount: Int
    public let databaseBytes: Int64
}
