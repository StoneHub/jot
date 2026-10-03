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
