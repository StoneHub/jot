import Foundation

/// The vocabulary entry a `vocabulary.save` request describes. With an id it edits that entry and keeps the fields the
/// request leaves out; without one it adds an entry. `PersonalVocabulary.save` still trims and checks what comes back.
public enum VocabularyRequest {
    /// Agents add entries one call at a time; this keeps a runaway loop from filling the list Settings shows.
    public static let maximumEntries = 1000

    public static func entry(_ params: [String: Any], in vocabulary: PersonalVocabulary) throws -> VocabularyEntry {
        func text(_ key: String) throws -> String? {
            guard let value = params[key] else { return nil }
            guard let string = value as? String else { throw VocabularyError.invalid("\(key) must be a string.") }
            return string
        }
        var entry: VocabularyEntry
        if let id = try text("id") {
            guard let uuid = UUID(uuidString: id), let existing = vocabulary.entries.first(where: { $0.id == uuid }) else {
                throw VocabularyError.invalid("No vocabulary entry has id \(id).")
            }
            entry = existing
        } else {
            guard vocabulary.entries.count < maximumEntries else { throw VocabularyError.invalid("Vocabulary holds at most \(maximumEntries) entries.") }
            guard params["preferred"] != nil else { throw VocabularyError.invalid("Enter a preferred spelling.") }
            entry = VocabularyEntry()
        }
        if let preferred = try text("preferred") { entry.preferred = preferred }
        if let heard = try text("heard") { entry.heard = heard }
        if let enabled = params["enabled"] {
            guard let number = enabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VocabularyError.invalid("enabled must be true or false.") }
            entry.enabled = number.boolValue
        }
        return entry
    }

    /// The id a `vocabulary.remove` request names, when an entry has it.
    public static func id(_ params: [String: Any], in vocabulary: PersonalVocabulary) throws -> UUID {
        guard let id = params["id"] as? String else { throw VocabularyError.invalid("id is required.") }
        guard let uuid = UUID(uuidString: id), vocabulary.entries.contains(where: { $0.id == uuid }) else {
            throw VocabularyError.invalid("No vocabulary entry has id \(id).")
        }
        return uuid
    }
}
