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

/// `you.json` in the Jot directory. Written atomically and user-only. A file of another version is ignored, and the
/// voice is learned again from the next holds.
public final class UserVoiceStore: @unchecked Sendable {
    public static let fileName = "you.json"
    public let url: URL
    private let lock = NSLock()

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    public func load() -> UserVoice? {
        guard let data = try? Data(contentsOf: url), let voice = try? JSONDecoder().decode(UserVoice.self, from: data),
              voice.version == UserVoice.currentVersion, voice.sampleCount >= 1, voice.heldSeconds >= 0,
              PeopleMatcher.normalized(voice.embedding) != nil else { return nil }
        return voice
    }

    /// Folds one session's held voice into the average, weighted by the samples already held, and keeps it unit length.
    /// An embedding of another size than the stored one starts over, as a new speaker model would.
    @discardableResult
    public func learn(_ embedding: [Float], heldSeconds: Double, now: Date = Date()) throws -> UserVoice {
        guard let unit = PeopleMatcher.normalized(embedding) else { throw StoreError.invalid("A voice needs a finite, nonzero embedding") }
        guard heldSeconds > 0, heldSeconds.isFinite else { throw StoreError.invalid("A voice is learned from held speech") }
        return try lock.withLock {
            let voice: UserVoice
            if let current = load(), current.embedding.count == unit.count {
                let count = Float(current.sampleCount)
                guard let averaged = PeopleMatcher.normalized(zip(current.embedding, unit).map { ($0 * count + $1) / (count + 1) }) else {
                    throw StoreError.invalid("Embeddings cancel out")
                }
                voice = UserVoice(embedding: averaged, sampleCount: current.sampleCount + 1,
                                  heldSeconds: current.heldSeconds + heldSeconds, updatedAt: now)
            } else {
                voice = UserVoice(embedding: unit, sampleCount: 1, heldSeconds: heldSeconds, updatedAt: now)
            }
            try JSONEncoder().encode(voice).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return voice
        }
    }

    /// Forget. Labels already written into sessions stay, as they do for a person.
    public func forget() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
}
