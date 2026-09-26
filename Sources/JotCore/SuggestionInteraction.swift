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
