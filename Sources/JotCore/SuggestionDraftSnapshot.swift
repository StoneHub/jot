import Foundation

/// Exact UTF-16 selection and value read from the field. Contains no inferred app or conversation state.
public struct SuggestionDraftSnapshot: Equatable, Sendable {
    public let value: String
    public let location: Int
    public let length: Int
    public init?(value: String, location: Int, length: Int) {
        let count = (value as NSString).length
        guard location >= 0, length >= 0, location <= count, length <= count - location else { return nil }
        self.value = value; self.location = location; self.length = length
    }
    /// Some hosts expose a hint as AXValue. Treat it as empty only when the host independently
    /// reports zero characters and an empty selection. Ambiguous or inconsistent values abstain.
    public static func accessibilityDraft(value: String, placeholder: String?, characterCount: Int?,
                                          location: Int, length: Int) -> Self? {
        if characterCount == 0, location == 0, length == 0,
           value.isEmpty || (placeholder != nil && value == placeholder) {
            return Self(value: "", location: 0, length: 0)
        }
        if let characterCount, characterCount != (value as NSString).length { return nil }
        if characterCount == nil, let placeholder, !placeholder.isEmpty, value == placeholder { return nil }
        return Self(value: value, location: location, length: length)
    }
    public var before: String { (value as NSString).substring(to: location) }
    public var after: String { (value as NSString).substring(from: location + length) }
    public var revision: Int {
        // Full value and selection are still compared at acceptance; this number is only the model's revision label.
        Int(ContentHash.sha256("\(location):\(length):" + value).prefix(12), radix: 16) ?? 0
    }
    public var selectedText: String { (value as NSString).substring(with: NSRange(location: location, length: length)) }
    /// Rich editors leave zero-width and non-breaking spaces in an empty field; none of them is a seed.
    public var isBlank: Bool { SuggestionSeed.isBlank(value) }
    /// Field text outside `seed`, which the draft prompt shows but the result never replaces.
    public func text(around seed: SuggestionSeed) -> (before: String, after: String) {
        let text = value as NSString
        return (text.substring(to: seed.location), text.substring(from: seed.location + seed.length))
    }
}
