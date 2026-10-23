import Foundation

/// The Fix typos shortcut on the event tap. Its key down and the matching key up are consumed so the field never sees
/// them; holding the key does not repeat the request. No Accessibility or AppKit calls.
public struct TypoFixKeyTracker {
    public struct Decision: Equatable {
        public var consume = false
        public var request = false
        public init(consume: Bool = false, request: Bool = false) { self.consume = consume; self.request = request }
    }
    private var consumedUp: UInt16?
    public init() {}
    public mutating func reset() { consumedUp = nil }

    /// `modifiers` without Fn, as the other shortcuts compare them.
    public mutating func handle(_ event: ShortcutTracker.Event, keyCode: UInt16, modifiers: ShortcutModifiers,
                                repeating: Bool, shortcut: DictationShortcut?) -> Decision {
        if event == .keyUp, consumedUp == keyCode { consumedUp = nil; return Decision(consume: true) }
        guard event == .keyDown, let shortcut, shortcut.keyCode == keyCode, modifiers == shortcut.modifiers else { return Decision() }
        consumedUp = keyCode
        return Decision(consume: true, request: !repeating)
    }
}
