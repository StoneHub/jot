import Foundation

public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var preferred: String
    public var heard: String
    public var enabled: Bool

    public init(id: UUID = UUID(), preferred: String = "", heard: String = "", enabled: Bool = true) {
        self.id = id; self.preferred = preferred; self.heard = heard; self.enabled = enabled
    }

    /// An empty heard phrase normalizes capitalization of the preferred spelling.
    public var matchPhrase: String { heard.isEmpty ? preferred : heard }
}

public struct PersonalVocabulary: Codable, Equatable, Sendable {
    public private(set) var entries: [VocabularyEntry] = []
    public init() {}

    public mutating func save(_ draft: VocabularyEntry) throws {
        var entry = draft
        entry.preferred = draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.heard = draft.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.preferred.isEmpty else { throw VocabularyError.invalid("Enter a preferred spelling.") }
        guard [entry.preferred, entry.heard].allSatisfy({ $0.count <= 200 && $0.rangeOfCharacter(from: .newlines) == nil }) else {
            throw VocabularyError.invalid("Use a single word or phrase, up to 200 characters per field.")
        }
        let key = Self.matchKey(entry.matchPhrase)
        guard !entries.contains(where: { $0.id != entry.id && Self.matchKey($0.matchPhrase) == key }) else {
            throw VocabularyError.invalid("That matching phrase already has an entry. Edit the existing entry instead.")
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.append(entry) }
    }

    public mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    private static func matchKey(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Match the original text once: leftmost first, longest at the same position.
    /// Literal insertion avoids regex replacement syntax and cascading corrections.
    public func applying(to text: String) -> String {
        let source = text as NSString
        var candidates: [(range: NSRange, replacement: String, order: Int)] = []
        for (order, entry) in entries.enumerated() where entry.enabled {
            let phrase = entry.matchPhrase.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            guard !phrase.isEmpty,
                  let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + phrase + ")(?![\\p{L}\\p{M}\\p{N}_])", options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                candidates.append((match.range, entry.preferred, order))
            }
        }
        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.order < $1.order
        }
        var result = "", cursor = 0
        for candidate in candidates where candidate.range.location >= cursor {
            result += source.substring(with: NSRange(location: cursor, length: candidate.range.location - cursor))
            result += candidate.replacement
            cursor = NSMaxRange(candidate.range)
        }
        result += source.substring(from: cursor)
        return result
    }
}

public enum VocabularyError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// A separate preference leaves transcript storage and recognition models untouched.
public final class VocabularyPreferences {
    private let defaults: UserDefaults
    private let key = "personalVocabulary"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> PersonalVocabulary {
        guard let data = defaults.data(forKey: key) else { return PersonalVocabulary() }
        let decoded = try JSONDecoder().decode(PersonalVocabulary.self, from: data)
        var validated = PersonalVocabulary()
        for entry in decoded.entries { try validated.save(entry) }
        return validated
    }
    public func save(_ vocabulary: PersonalVocabulary) throws {
        defaults.set(try JSONEncoder().encode(vocabulary), forKey: key)
    }
}
