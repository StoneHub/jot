import Foundation

public enum SuggestionOutput {
    /// A field hint or verbatim draft echo is not a useful new input. No app-specific phrase blacklist.
    public static func isFieldEcho(_ text: String, draft: SuggestionDraftSnapshot, placeholder: String?) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        }
        let candidate = normalized(text)
        guard !candidate.isEmpty else { return true }
        return candidate == normalized(draft.value)
            || placeholder.map { !normalized($0).isEmpty && candidate == normalized($0) } == true
    }

    public static func process(_ raw: String, mode: SuggestionMode, singleLine: Bool = false) -> ProcessedOutput {
        let trimming: CharacterSet = mode == .continuation ? .newlines : .whitespacesAndNewlines
        var text = raw.trimmingCharacters(in: trimming)
        if text.count >= 2, let first = text.first, first == text.last, first == "`" || first == "\"" {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: trimming)
        }
        if mode == .draft { text = unwrapDraft(text) }
        let marker = SuggestionPrompt.abstainMarker
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .abstained("empty-output") }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == marker || normalized == marker + "." { return .abstained("model-abstained") }
        if text.contains(marker) { return .rejected("mixed-abstain-marker") }
        if text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) {
            return .rejected("control-characters")
        }
        if mode == .shellCommand && text.contains("\n") { return .rejected("multiline-shell-command") }
        if singleLine && text.contains("\n") { return .rejected("multiline-single-line-field") }
        // A finished draft may have paragraphs, such as an email body; the other modes insert one.
        if mode != .draft && text.contains("\n\n") { return .rejected("multiple-paragraphs") }
        return .suggestion(text)
    }

    /// Small models sometimes echo the prompt's own label or wrap the result in typographic quotes.
    private static func unwrapDraft(_ text: String) -> String {
        var text = text
        for label in ["finished text:", "notes to rewrite:", "rewritten text:", "draft:"] where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count >= 2, text.first == "\u{201C}", text.last == "\u{201D}" {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    public enum Review: Equatable, Sendable {
        case accept
        /// The draft only changes spacing, punctuation or letter case, or repeats the field; a continuation restates it.
        case unchanged
        /// The result repeats or merely rewords the field's hint.
        case restatesHint
        /// The result copies text already on screen, such as the question it should answer.
        case copiesContext
    }

    /// Checks after processing that catch outputs that look valid but are not a useful new input.
    public static func review(_ text: String, draft: SuggestionDraftSnapshot, seed: String?, placeholder: String?,
                              context: String?) -> Review {
        let candidate = FieldHint.normalized(text)
        if candidate == FieldHint.normalized(draft.value) || seed.map({ FieldHint.normalized($0) == candidate }) == true {
            return .unchanged
        }
        // Same words in the same order: a rewrite that only moves a space or a full stop ("me.Then" to "me. Then").
        if let seed, words(text) == words(seed) { return .unchanged }
        if seed == nil, !draft.isBlank, repeats(text, draft: draft.value) { return .unchanged }
        if isFieldEcho(text, draft: draft, placeholder: placeholder) || restatesHint(text, hint: placeholder) {
            return .restatesHint
        }
        if let context, copies(text, context: context, seed: seed) { return .copiesContext }
        return .accept
    }

    /// A reply copies the screen when it is a verbatim run of it. A draft's own notes may be on screen, and a rewrite may
    /// restore a word shown there, so a draft copies only when its words are mostly not the notes' and its wording is
    /// on screen, verbatim or lightly edited.
    static func copies(_ text: String, context: String, seed: String?) -> Bool {
        let candidate = FieldHint.normalized(text)
        let verbatim = candidate.count >= 24 && FieldHint.normalized(context).contains(candidate)
        guard let seed else { return verbatim }
        let textWords = words(text), textRuns = runs(textWords)
        let shown = Set(runs(words(context))), notes = Set(words(seed))
        let mostlyShown = textRuns.count >= 3 && textRuns.filter(shown.contains).count * 2 >= textRuns.count
        return (verbatim || mostlyShown) && textWords.filter(notes.contains).count * 2 < textWords.count
    }

    /// A continuation repeats the user's text when at least half of its four-word runs are already there, or, when it is
    /// shorter than one run, when the text contains it whole.
    static func repeats(_ text: String, draft: String) -> Bool {
        let textWords = words(text), draftWords = words(draft)
        guard !textWords.isEmpty else { return true }
        let textRuns = runs(textWords)
        guard !textRuns.isEmpty else {
            return " \(draftWords.joined(separator: " ")) ".contains(" \(textWords.joined(separator: " ")) ")
        }
        let typed = Set(runs(draftWords))
        return textRuns.filter(typed.contains).count * 2 >= textRuns.count
    }

    /// What a continuation inserts at the cursor. The on-device model often restates the user's text before continuing
    /// it; that restatement is dropped. One space separates the new text from a word or sentence before the cursor.
    /// Empty when nothing new is left.
    public static func continuation(_ text: String, before: String) -> String {
        let isSpace = { (character: Character) in character == " " || character == "\t" }
        var body = Substring(text).drop(while: isSpace)
        for mark in ["...", "…"] where body.hasPrefix(mark) { body = body.dropFirst(mark.count).drop(while: isSpace) }
        let typed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, body.hasPrefix(typed) { body = body.dropFirst(typed.count) }
        body = droppingOverlap(body, before: before).drop(while: isSpace)
        guard let first = body.first else { return "" }
        guard let last = before.last, !last.isWhitespace, !".,;:!?)]}”’".contains(first) else { return String(body) }
        return " " + body
    }

    /// Drops the words at the start of `text` that repeat the last words before the cursor, case and punctuation aside:
    /// asked to finish "check whether the export guard", the model often starts "Check whether the export guard still…".
    /// Two words or more, so a continuation that merely starts like the text is kept.
    static func droppingOverlap(_ text: Substring, before: String) -> Substring {
        let tail = Array(words(before).suffix(12))
        let isWord = { (character: Character) in character.isLetter || character.isNumber }
        var ranges: [Range<Substring.Index>] = []
        var index = text.startIndex
        while ranges.count < tail.count, let start = text[index...].firstIndex(where: isWord) {
            let end = text[start...].firstIndex { !isWord($0) } ?? text.endIndex
            ranges.append(start..<end); index = end
        }
        let head = ranges.map { text[$0].lowercased() }
        for count in stride(from: min(head.count, tail.count), through: 2, by: -1) where Array(tail.suffix(count)) == Array(head.prefix(count)) {
            return text[ranges[count - 1].upperBound...]
        }
        return text
    }

    /// Every word of the hint plus at most a few more reads as the hint reworded ("Ask Codex anything you like").
    static func restatesHint(_ text: String, hint: String?) -> Bool {
        guard let hint else { return false }
        let hintWords = Set(words(hint)), candidate = words(text)
        guard hintWords.count >= 2 else { return false }
        return hintWords.isSubset(of: Set(candidate)) && candidate.count <= hintWords.count + 4
    }

    private static func words(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Consecutive four-word runs; punctuation and Markdown between words don't break a run.
    private static func runs(_ words: [String]) -> [String] {
        words.count < 4 ? [] : (0...(words.count - 4)).map { words[$0..<$0 + 4].joined(separator: " ") }
    }
}
