import Foundation

/// The one stretch of a field a typo fix replaces: from the first changed character to the last, in UTF-16 units as
/// Accessibility counts them. Both sides are kept non-empty, because inserting empty text deletes nothing, so the same
/// edit can be applied and then undone by swapping its sides.
public struct TypoFixEdit: Equatable, Sendable {
    public let location: Int
    public let original: String
    public let replacement: String
    public var length: Int { (original as NSString).length }

    public init(location: Int, original: String, replacement: String) {
        self.location = location; self.original = original; self.replacement = replacement
    }

    /// Nil when the texts are the same. `offset` places the source within its field, such as a selection's start.
    public init?(source: String, corrected: String, offset: Int = 0) {
        guard source != corrected else { return nil }
        let a = Array(source), b = Array(corrected)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        while prefix + suffix == a.count || prefix + suffix == b.count {
            if prefix > 0 { prefix -= 1 } else if suffix > 0 { suffix -= 1 } else { break }
        }
        let original = String(a[prefix..<(a.count - suffix)])
        location = offset + (String(a[..<prefix]) as NSString).length
        self.original = original
        replacement = String(b[prefix..<(b.count - suffix)])
    }

    /// The edit that puts the original back once this one is applied.
    public var reversed: TypoFixEdit { TypoFixEdit(location: location, original: replacement, replacement: original) }

    /// The field value once this edit is applied to `value`.
    public func applied(to value: String) -> String? {
        let text = value as NSString
        guard location + length <= text.length, text.substring(with: NSRange(location: location, length: length)) == original else { return nil }
        return text.replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
    }

    /// The range `DictationInput.replace` selects before inserting the replacement.
    public var seed: SuggestionSeed { SuggestionSeed(text: original, location: location, length: length, isSelection: true) }
}
