import Foundation

/// The user's own notes for a draft, and the exact UTF-16 range they occupy. Tab replaces only this range.
public struct SuggestionSeed: Equatable, Sendable {
    public let text: String
    public let location: Int
    public let length: Int
    /// The user selected these notes; otherwise the seed is the whole field.
    public let isSelection: Bool

    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\u{200B}" || $0 == "\u{FEFF}" }
    }
}
