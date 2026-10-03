import Foundation

/// One speech model Jot downloads the first time it loads.
public struct ModelDownload: Sendable, Identifiable, Equatable {
    public let name: String
    public let purpose: String
    public let bytes: Int64
    public var id: String { name }
    public init(name: String, purpose: String, bytes: Int64) {
        self.name = name; self.purpose = purpose; self.bytes = bytes
    }
}
