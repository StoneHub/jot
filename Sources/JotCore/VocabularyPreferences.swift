import Foundation

/// A separate preference leaves transcript storage and recognition models untouched.
public final class VocabularyPreferences {
    private let defaults: UserDefaults
    private let key = JotDefaultsKey.personalVocabulary
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
