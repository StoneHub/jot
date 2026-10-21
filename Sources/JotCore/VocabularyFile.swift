import Foundation

/// The versioned JSON file `jot vocabulary export` writes and `jot vocabulary import` reads, and the one Jot for Android
/// is to read. docs/SHARED-CONTRACT.md is its spec. Entry ids stay on the Mac that made them, so an import matches
/// entries by phrase, the way the list itself refuses duplicates.
public enum VocabularyFile {
    public static let formatName = "jot.vocabulary"
    public static let currentVersion = 1
    /// 1,000 entries of two 200-character fields fit with room to spare; anything larger is not an export.
    public static let maximumBytes = 2_000_000

    public struct Entry: Codable, Equatable, Sendable {
        public var preferred: String
        public var heard: String
        public var enabled: Bool

        public init(preferred: String, heard: String = "", enabled: Bool = true) {
            self.preferred = preferred; self.heard = heard; self.enabled = enabled
        }

        /// A hand-written file may leave out `heard` (capitalization only) and `enabled` (on).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preferred = try container.decode(String.self, forKey: .preferred)
            heard = try container.decodeIfPresent(String.self, forKey: .heard) ?? ""
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    private struct Contents: Codable {
        var format: String
        var version: Int
        var entries: [Entry]
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    /// The list in its order, which decides between two entries that match at the same place. Ids are left out.
    public static func encode(_ entries: [VocabularyEntry]) throws -> Data {
        let contents = Contents(format: formatName, version: currentVersion,
                                entries: entries.map { Entry(preferred: $0.preferred, heard: $0.heard, enabled: $0.enabled) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(contents) + Data("\n".utf8)
    }

    /// Reads a file of this version or an earlier one. A newer version is refused rather than read in part.
    /// Fields this version does not know are ignored, so a later version may add optional ones without a new number.
    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumBytes else { throw VocabularyError.invalid("That file is too large to be a vocabulary export.") }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == formatName,
              let version = header.version, version >= 1 else {
            throw VocabularyError.invalid("That file is not a Jot vocabulary export.")
        }
        guard version <= currentVersion else {
            throw VocabularyError.invalid("That file uses vocabulary version \(version), which this Jot cannot read. Update Jot to import it.")
        }
        do { return try JSONDecoder().decode(Contents.self, from: data).entries }
        catch { throw VocabularyError.invalid("The entries in that file could not be read.") }
    }

    /// The entries an import adds, in file order, and how many it skips. An entry whose phrase the list already has,
    /// or that an earlier entry in the file already added, is skipped, so an import never changes or removes an entry.
    /// Every addition is checked against the list first, so a bad file throws before anything is saved.
    public static func additions(_ entries: [Entry], to vocabulary: PersonalVocabulary) throws -> (added: [Entry], skipped: Int) {
        var trial = vocabulary, added: [Entry] = [], skipped = 0
        for (index, entry) in entries.enumerated() {
            let draft = VocabularyEntry(preferred: entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines),
                                        heard: entry.heard.trimmingCharacters(in: .whitespacesAndNewlines), enabled: entry.enabled)
            let key = PersonalVocabulary.matchKey(draft.matchPhrase)
            if !key.isEmpty, trial.entries.contains(where: { PersonalVocabulary.matchKey($0.matchPhrase) == key }) { skipped += 1; continue }
            guard trial.entries.count < VocabularyRequest.maximumEntries else {
                throw VocabularyError.invalid("Importing would pass \(VocabularyRequest.maximumEntries) vocabulary entries. Nothing was imported.")
            }
            do { try trial.save(draft) }
            catch { throw VocabularyError.invalid("Entry \(index + 1): \(error.localizedDescription) Nothing was imported.") }
            added.append(Entry(preferred: draft.preferred, heard: draft.heard, enabled: draft.enabled))
        }
        return (added, skipped)
    }
}
