import Foundation

/// Web editors (ProseMirror, TipTap and others) often draw their hint as CSS-generated text inside the editable
/// element, and Chromium then reports that hint as the field's AXValue. The DOM class of the element that holds
/// the text is the generic evidence Accessibility exposes. No app-specific phrase list.
public enum FieldHint {
    public static func isHintClass(_ classes: [String]) -> Bool {
        classes.contains { token in
            let lower = token.lowercased()
            return lower.contains("placeholder") || lower == "is-empty" || lower == "is-editor-empty"
        }
    }

    /// True only when everything the field reports is hint text, so a user who typed the same words keeps them.
    public static func valueIsHint(_ value: String, hints: [String]) -> Bool {
        let text = normalized(value)
        guard !text.isEmpty, !hints.isEmpty else { return false }
        return hints.contains { normalized($0) == text } || normalized(hints.joined(separator: " ")) == text
    }

    static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
