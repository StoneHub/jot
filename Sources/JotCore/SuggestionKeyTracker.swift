import Foundation

/// No Accessibility or AppKit calls. A consumed down keeps its paired up even after dismissal.
public struct SuggestionKeyTracker {
    public enum State: Equatable { case idle, requesting, loading, ready, notice, accepting }
    public enum Action: Equatable { case none, request, accept, dismiss }
    public struct Decision: Equatable {
        public var action: Action
        public var consume: Bool
        /// The key went to the system screenshot tool, not the field, so it does not count as an edit.
        public var screenshot: Bool
        public init(_ action: Action = .none, consume: Bool = false, screenshot: Bool = false) {
            self.action = action; self.consume = consume; self.screenshot = screenshot
        }
    }
    public private(set) var state: State = .idle
    private var consumedUps: Set<UInt16> = []
    /// While the interactive screenshot tool is up, its keys (Space, Escape, Return) reach it untouched and leave the card.
    private var screenshotUntil: TimeInterval?
    static let screenshotHold: TimeInterval = 15
    public init() {}
    public mutating func show(_ state: State) { self.state = state }
    public mutating func dismiss() { state = .idle; screenshotUntil = nil }
    public mutating func reset() { state = .idle; consumedUps.removeAll(); screenshotUntil = nil }
    public mutating func endScreenshot() { screenshotUntil = nil }

    /// macOS screenshot chords: Shift-Command-3/4/5/6, with or without Control to copy.
    /// Returns whether the chord opens an interactive tool (4 and 5); 3 and 6 capture at once. Nil for other keys.
    static func screenshotChord(keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool? {
        guard modifiers.isSuperset(of: [.command, .shift]),
              modifiers.subtracting([.command, .shift, .control]).isEmpty else { return nil }
        switch keyCode {
        case 21, 23: return true
        case 20, 22: return false
        default: return nil
        }
    }

    public mutating func handle(_ event: ShortcutTracker.Event, keyCode: UInt16,
                                modifiers: ShortcutModifiers, repeating: Bool = false,
                                shortcut: DictationShortcut?, allowed: Bool,
                                at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Decision {
        if ShortcutTracker.isFnCompanionEvent(event, keyCode: keyCode) { return Decision() }
        if event == .keyUp, consumedUps.remove(keyCode) != nil { return Decision(consume: true) }
        guard event == .keyDown else { return Decision() }
        if let until = screenshotUntil, time >= until { screenshotUntil = nil }
        if state != .idle, let interactive = Self.screenshotChord(keyCode: keyCode, modifiers: modifiers) {
            if interactive { screenshotUntil = time + Self.screenshotHold }
            return Decision(screenshot: true)
        }
        let explicit = allowed && !repeating && ((keyCode == shortcut?.keyCode && modifiers == shortcut?.modifiers)
            || (state == .ready && modifiers.isEmpty && keyCode == 48))
        if state != .idle, screenshotUntil != nil, !explicit {
            // Escape cancels and Return confirms the capture; either ends the tool.
            if !repeating && modifiers.isEmpty && (keyCode == 53 || keyCode == 36 || keyCode == 76) { screenshotUntil = nil }
            return Decision(screenshot: true)
        }
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
        // Escape is the card's own key only while there is something to cancel: a request in flight or a result to insert.
        // A "No suggestion" notice is dismissed by any key, and that key still reaches the app.
        if (state == .loading || state == .ready) && modifiers.isEmpty && keyCode == 53 {
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
