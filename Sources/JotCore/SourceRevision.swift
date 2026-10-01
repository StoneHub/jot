import Foundation

public struct SourceRevision: Decodable, Equatable, Sendable, Hashable {
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
    public let id: String
    public let revision: Int
}
