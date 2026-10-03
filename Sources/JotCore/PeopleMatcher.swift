import Foundation
import SQLite3

/// Finds the remembered voice nearest to a session speaker's embedding. Pure.
public enum PeopleMatcher {
    /// Same measure and default as FluidAudio's SpeakerManager (Sources/FluidAudio/Diarizer/Clustering/SpeakerManager.swift, speakerThreshold: Float = 0.65; findSpeaker matches when distance <= threshold, where SpeakerUtilities.cosineDistance is 1 - cosine similarity). The WeSpeaker embeddings the pass stores were tuned for that measure, so Jot uses the same one.
    public static let threshold: Float = 0.65

    /// How names compare: trimmed, ignoring case and width, so "Ada " and "ada" are one person.
    public static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// The nearest person at or under the threshold, or nil. A person whose embedding has a different length is skipped.
    public static func match(embedding: [Float], people: [Person], threshold: Float = threshold) -> (id: String, distance: Float)? {
        people.compactMap { person in distance(embedding, person.embedding).map { (person.id, $0) } }
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }
            .map { (id: $0.0, distance: $0.1) }
    }

    /// Pairs each session speaker with at most one person and each person with at most one speaker, nearest pair first, all at or under the threshold.
    public static func assignments(speakers: [String: [Float]], people: [Person], threshold: Float = threshold) -> [(speaker: String, id: String, distance: Float)] {
        let pairs = speakers.flatMap { speaker, embedding in people.compactMap { person in distance(embedding, person.embedding).map { (speaker: speaker, id: person.id, distance: $0) } } }
            .filter { $0.distance <= threshold }
            .sorted { ($0.distance, $0.speaker, $0.id) < ($1.distance, $1.speaker, $1.id) }
        var result: [(speaker: String, id: String, distance: Float)] = []
        for pair in pairs where !result.contains(where: { $0.speaker == pair.speaker || $0.id == pair.id }) { result.append(pair) }
        return result
    }

    /// 1 - cosine similarity: 0 for the same direction, 2 for opposite. Nil for empty, mismatched, or zero-length vectors.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let magnitudes = a.reduce(0) { $0 + $1 * $1 }.squareRoot() * b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magnitudes > 0, magnitudes.isFinite, dot.isFinite else { return nil }
        return 1 - min(max(dot / magnitudes, -1), 1)
    }

    /// The vector scaled to unit length; nil when it is empty, not finite, or all zeros.
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let magnitude = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return vector.map { $0 / magnitude }
    }
}
