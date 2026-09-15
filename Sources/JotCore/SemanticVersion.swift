/// A dotted numeric version such as 0.1.10; compared component by component, never as text.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public init(_ components: [Int]) { self.components = components }
    /// Accepts "1.2.3" or "v1.2.3"; anything with a non-numeric part is nil.
    public static func parse(_ text: String) -> SemanticVersion? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        guard !body.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(piece), number >= 0 else { return nil }
            parts.append(number)
        }
        return SemanticVersion(parts)
    }
    public var description: String { components.map(String.init).joined(separator: ".") }
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
