import Foundation

public enum TextDistance {
    /// Edits (insert, delete, substitute, or swap two neighbors) that turn `a` into `b`, counting each swap as one, as a
    /// typo usually is. Returns `limit + 1` for anything over `limit`, at once when the lengths alone differ by more.
    public static func optimalStringAlignment(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        if a.isEmpty || b.isEmpty { return min(max(a.count, b.count), limit + 1) }
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                var cost = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cost = min(cost, twoBack[j - 2] + 1) }
                current[j] = cost
            }
            (twoBack, previous, current) = (previous, current, twoBack)
        }
        return min(previous[b.count], limit + 1)
    }
}
