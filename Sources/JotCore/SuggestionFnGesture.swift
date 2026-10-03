import Foundation

/// Fn request recognition when Fn is not also the active dictation shortcut.
/// Shares dictation's short-tap timing and rejects intervening typing and modifier chords.
public struct SuggestionFnGesture {
    private var tracker = ShortcutTracker()
    public init() {}
    public mutating func reset() { tracker.reset() }
    public mutating func handle(_ event: ShortcutTracker.Event, keyCode: UInt16,
                                modifiers: ShortcutModifiers, at time: TimeInterval, enabled: Bool) -> Bool {
        guard enabled else { tracker.reset(); return false }
        return tracker.handle(event, keyCode: keyCode, modifiers: modifiers, shortcut: .fn, at: time).action == .doubleTap
    }
}
