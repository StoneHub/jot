import Foundation

/// The user's own voice: the running average of the speaker-pass embeddings of the voice heard during dictation holds,
/// kept in a small file of its own next to the database, so a format rebuild does not lose it. Embeddings only; no
/// audio. Trusted, and used, only once enough held speech has gone into it.
public struct UserVoice: Codable, Equatable, Sendable {
    /// The speaker label the pass writes for the user's voice, and the name People shows. Not a person: never remembered as one.
    public static let label = "You"
    /// Seconds of held dictation the voice must be learned from before Jot acts on it.
    public static let minimumHeldSeconds = 20.0
    public static let currentVersion = 1

    public var version: Int
    public var embedding: [Float]
    public var sampleCount: Int
    /// Seconds of held dictation the samples were learned from.
    public var heldSeconds: Double
    public var updatedAt: Date

    public init(embedding: [Float], sampleCount: Int, heldSeconds: Double, updatedAt: Date) {
        version = Self.currentVersion
        self.embedding = embedding; self.sampleCount = sampleCount; self.heldSeconds = heldSeconds; self.updatedAt = updatedAt
    }

    public var trusted: Bool { heldSeconds >= Self.minimumHeldSeconds }

    /// Same measure and threshold as People. Nil for an embedding of another size.
    public func distance(to other: [Float]) -> Float? { PeopleMatcher.distance(embedding, other) }

    /// A trusted voice within the People threshold of `other`.
    public func matches(_ other: [Float], threshold: Float = PeopleMatcher.threshold) -> Bool {
        trusted && (distance(to: other).map { $0 <= threshold } ?? false)
    }
}
