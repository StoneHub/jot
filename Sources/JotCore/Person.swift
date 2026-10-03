import Foundation
import SQLite3

/// One remembered voice: a name and the running average of the speaker-pass embeddings saved for it.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var embedding: [Float]
    public var sampleCount: Int
    public let createdAt: Date
    public var updatedAt: Date
}
