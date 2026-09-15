import Foundation

/// Quartz keyboard events carry at most 20 UTF-16 units. Never split a surrogate pair.
public enum UnicodeTyping {
    public static func chunks(_ text: String) -> [[UInt16]] {
        let units = Array(text.utf16)
        var result: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }
}
