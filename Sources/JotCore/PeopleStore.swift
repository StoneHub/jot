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

/// Voices the user asked Jot to remember, kept in the transcripts database on a connection of its own. Deleting a person forgets the voice; session labels already written stay.
public final class PeopleStore: @unchecked Sendable {
    private let db: SQLiteConnection

    /// Opens after `store`, which created the table.
    public init(sharing store: TranscriptStore) throws {
        db = try SQLiteConnection(url: store.databaseURL)
    }

    public func list() throws -> [Person] {
        try db.locked {
            let stmt = try db.prepare("SELECT id,name,embedding,sample_count,created_at,updated_at FROM people ORDER BY name COLLATE NOCASE, created_at")
            defer { sqlite3_finalize(stmt) }
            var result: [Person] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                result.append(Person(id: db.column(stmt, 0)!, name: db.column(stmt, 1)!, embedding: SpeakerPassStore.floats(db.blob(stmt, 2)), sampleCount: Int(sqlite3_column_int64(stmt, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))))
            }
            return result
        }
    }

    @discardableResult
    public func add(name: String, embedding: [Float], now: Date = Date()) throws -> Person {
        let trimmed = try Self.validName(name)
        guard let unit = PeopleMatcher.normalized(embedding) else { throw StoreError.invalid("A voice needs a finite, nonzero embedding") }
        let person = Person(id: UUID().uuidString, name: trimmed, embedding: unit, sampleCount: 1, createdAt: now, updatedAt: now)
        try db.locked {
            let stmt = try db.prepare("INSERT INTO people(id,name,embedding,sample_count,created_at,updated_at) VALUES(?,?,?,1,?,?)")
            defer { sqlite3_finalize(stmt) }
            db.bind(person.id, to: 1, in: stmt); db.bind(person.name, to: 2, in: stmt); db.bind(SpeakerPassStore.blob(unit), to: 3, in: stmt)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970); sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            try db.finish(stmt)
        }
        return person
    }

    public func rename(id: String, name: String) throws {
        let trimmed = try Self.validName(name)
        try db.locked {
            let stmt = try db.prepare("UPDATE people SET name = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            db.bind(trimmed, to: 1, in: stmt); db.bind(id, to: 2, in: stmt)
            try db.finish(stmt)
            guard db.changes == 1 else { throw StoreError.invalid("No person with that id") }
        }
    }

    public func delete(id: String) throws {
        try db.locked {
            let stmt = try db.prepare("DELETE FROM people WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            db.bind(id, to: 1, in: stmt)
            try db.finish(stmt)
            guard db.changes == 1 else { throw StoreError.invalid("No person with that id") }
        }
    }

    /// Folds one more voice sample into the stored average, weighted by how many it already holds, and keeps the result unit length.
    public func updateEmbedding(id: String, with embedding: [Float], now: Date = Date()) throws {
        guard let unit = PeopleMatcher.normalized(embedding) else { throw StoreError.invalid("A voice needs a finite, nonzero embedding") }
        try db.locked {
            try db.transaction {
                let find = try db.prepare("SELECT embedding,sample_count FROM people WHERE id = ?")
                defer { sqlite3_finalize(find) }
                db.bind(id, to: 1, in: find)
                guard sqlite3_step(find) == SQLITE_ROW else { throw StoreError.invalid("No person with that id") }
                let stored = SpeakerPassStore.floats(db.blob(find, 0))
                let count = Float(sqlite3_column_int64(find, 1))
                guard stored.count == unit.count else { throw StoreError.invalid("Embedding sizes differ") }
                guard let averaged = PeopleMatcher.normalized(zip(stored, unit).map { ($0 * count + $1) / (count + 1) }) else { throw StoreError.invalid("Embeddings cancel out") }
                let update = try db.prepare("UPDATE people SET embedding = ?, sample_count = sample_count + 1, updated_at = ? WHERE id = ?")
                defer { sqlite3_finalize(update) }
                db.bind(SpeakerPassStore.blob(averaged), to: 1, in: update); sqlite3_bind_double(update, 2, now.timeIntervalSince1970); db.bind(id, to: 3, in: update)
                try db.finish(update)
            }
        }
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw StoreError.invalid("A name of at most 200 characters is required") }
        return trimmed
    }
}

/// Finds the remembered voice nearest to a session speaker's embedding. Pure.
public enum PeopleMatcher {
    /// Same measure and default as FluidAudio's SpeakerManager (Sources/FluidAudio/Diarizer/Clustering/SpeakerManager.swift, speakerThreshold: Float = 0.65; findSpeaker matches when distance <= threshold, where SpeakerUtilities.cosineDistance is 1 - cosine similarity). The WeSpeaker embeddings the pass stores were tuned for that measure, so Jot uses the same one.
    public static let threshold: Float = 0.65

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
