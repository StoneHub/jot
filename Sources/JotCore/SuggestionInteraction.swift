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
    public func mode(bundleID: String, role: String) -> SuggestionMode? {
        if !value.isEmpty { return .continuation }
        return bundleID == "com.openai.codex" && role == "AXTextArea" ? .reply : nil
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

/// What one explicit request does with the focused field, decided before any model call.
public enum SuggestionPlan: Equatable, Sendable {
    /// Turn the user's notes into finished text that replaces them. Transcripts are not needed.
    case draft(SuggestionSeed)
    /// Suggest the user's next message at the cursor of a blank composer.
    case reply
    /// A blank field with nothing associated with it. Ask for rough notes rather than paraphrase the field hint.
    case needsNotes

    /// A selection is the seed when it holds text; otherwise the whole draft is. A blank field needs a multi-line
    /// composer plus context associated with it (the visible conversation, or dictation meant for it).
    public static func make(draft: SuggestionDraftSnapshot, role: String, hasAssociatedContext: Bool) -> SuggestionPlan {
        if !draft.isBlank {
            if draft.length > 0, !SuggestionSeed.isBlank(draft.selectedText) {
                return .draft(SuggestionSeed(text: draft.selectedText, location: draft.location, length: draft.length, isSelection: true))
            }
            return .draft(SuggestionSeed(text: draft.value, location: 0, length: (draft.value as NSString).length, isSelection: false))
        }
        return role == "AXTextArea" && hasAssociatedContext ? .reply : .needsNotes
    }
}

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

/// No Accessibility or AppKit calls. A consumed down keeps its paired up even after dismissal.
public struct SuggestionKeyTracker {
    public enum State: Equatable { case idle, requesting, loading, ready, notice, accepting }
    public enum Action: Equatable { case none, request, accept, dismiss }
    public struct Decision: Equatable {
        public var action: Action
        public var consume: Bool
        public init(_ action: Action = .none, consume: Bool = false) { self.action = action; self.consume = consume }
    }
    public private(set) var state: State = .idle
    private var consumedUps: Set<UInt16> = []
    public init() {}
    public mutating func show(_ state: State) { self.state = state }
    public mutating func dismiss() { state = .idle }
    public mutating func reset() { state = .idle; consumedUps.removeAll() }

    public mutating func handle(_ event: ShortcutTracker.Event, keyCode: UInt16,
                                modifiers: ShortcutModifiers, repeating: Bool = false,
                                shortcut: DictationShortcut?, allowed: Bool) -> Decision {
        if ShortcutTracker.isFnCompanionEvent(event, keyCode: keyCode) { return Decision() }
        if event == .keyUp, consumedUps.remove(keyCode) != nil { return Decision(consume: true) }
        guard event == .keyDown else { return Decision() }
        // Repeats and modified Tab/Escape never invoke an action or get swallowed.
        if repeating {
            if state != .idle { state = .idle; return Decision(.dismiss) }
            return Decision()
        }
        if allowed, state != .accepting, let shortcut, keyCode == shortcut.keyCode,
           modifiers == shortcut.modifiers {
            consumedUps.insert(keyCode); state = .requesting
            return Decision(.request, consume: true)
        }
        let cardVisible = state == .loading || state == .ready || state == .notice
        if cardVisible && modifiers.isEmpty && keyCode == 53 {
            consumedUps.insert(keyCode); state = .idle
            return Decision(.dismiss, consume: true)
        }
        if allowed && state == .ready && modifiers.isEmpty && keyCode == 48 {
            consumedUps.insert(keyCode); state = .accepting
            return Decision(.accept, consume: true)
        }
        if state != .idle {
            state = .idle
            return Decision(.dismiss)
        }
        return Decision()
    }
}

public final class SuggestionShortcutPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> DictationShortcut? {
        guard let data = defaults.data(forKey: JotDefaultsKey.suggestionShortcut),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              value.isValid, value.keyCode != nil else { return nil }
        return value
    }
    public func save(_ shortcut: DictationShortcut, dictation: DictationShortcut) throws {
        guard shortcut.isValid, shortcut.keyCode != nil,
              shortcut.keyCode != dictation.keyCode || shortcut.modifiers != dictation.modifiers else {
            throw NSError(domain: "JotShortcut", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a modified key different from the dictation shortcut."])
        }
        defaults.set(try JSONEncoder().encode(shortcut), forKey: JotDefaultsKey.suggestionShortcut)
    }
}

/// Debounces automatic requests and remembers the last attempted draft, including abstentions and dismissal.
/// A failed/no-result request is not retried until the target changes; accepted text can be suppressed too.
public struct SuggestionAutomaticTrigger<Key: Equatable> {
    private var observed: Key?
    private var attempted: Key?
    private var stableSince: TimeInterval = 0
    private var nextRequest: TimeInterval = 0
    public init() {}
    public mutating func observe(_ key: Key?, at now: TimeInterval) -> Bool {
        guard let key else { observed = nil; return false }
        if observed != key { observed = key; stableSince = now; return false }
        guard attempted != key, now - stableSince >= 0.75, now >= nextRequest else { return false }
        attempted = key; nextRequest = now + 2
        return true
    }
    public mutating func suppress(_ key: Key, at now: TimeInterval) {
        observed = key; attempted = key; stableSince = now; nextRequest = now + 2
    }
}

/// Fn request recognition when Fn is not also the active dictation shortcut.
/// Shares dictation's short-tap timing and rejects intervening typing and modifier chords.
public struct SuggestionFnGesture {
    private var tracker = ShortcutTracker()
    public init() {}
    public mutating func reset() { tracker.reset() }
    public mutating func handle(_ event: ShortcutTracker.Event, keyCode: UInt16,
                                modifiers: ShortcutModifiers, at time: TimeInterval, enabled: Bool) -> Bool {
        guard enabled else { tracker.reset(); return false }
        return tracker.handle(event, keyCode: keyCode, modifiers: modifiers, shortcut: .fn, at: time).action == .recover
    }
}
