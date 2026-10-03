import Foundation

/// Physical-key state is separate from capture state: repeats cannot restart an utterance,
/// and the trigger's key-up remains consumed even when its modifiers were released first.
public struct ShortcutTracker {
    public enum Event { case keyDown, keyUp, flagsChanged }
    public enum Action: Equatable { case none, start, stop, discardTap, doubleTap, cancel }
    public struct Result: Equatable {
        public var action: Action = .none
        public var consume = false
    }
    public static let shortTapMaximumDuration: TimeInterval = 0.2
    public static let doubleTapMaximumInterval: TimeInterval = 0.35

    /// The physical Fn flags events are authoritative. Some Macs also emit a non-text
    /// key pair after Fn release: 179 was recorded on the supported Mac; 63 is Fn itself.
    public static func isFnCompanionEvent(_ event: Event, keyCode: UInt16) -> Bool {
        event != .flagsChanged && (keyCode == 63 || keyCode == 179)
    }

    private var held = false
    private var suppressKeyUp = false
    private var suppressFnUntilRelease = false
    private var pressedAt: TimeInterval?
    private var doubleTapCandidate = false
    private var lastShortReleaseAt: TimeInterval?
    public init() {}
    public mutating func reset() {
        held = false
        suppressKeyUp = false
        suppressFnUntilRelease = false
        pressedAt = nil
        doubleTapCandidate = false
        lastShortReleaseAt = nil
    }

    public mutating func handle(_ event: Event, keyCode: UInt16, modifiers: ShortcutModifiers,
                                repeating: Bool = false, shortcut: DictationShortcut,
                                at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Result {
        if Self.isFnCompanionEvent(event, keyCode: keyCode) { return Result() }
        expireTapSequence(at: timestamp)
        if shortcut.keyCode == nil {
            if suppressFnUntilRelease {
                if event == .flagsChanged && !modifiers.contains(.fn) { suppressFnUntilRelease = false }
                return Result()
            }
            if event == .keyDown {
                // Fn's own key events (63, and 179 after release) were already ignored above.
                if held {
                    cancelGesture()
                    suppressFnUntilRelease = true
                    return Result(action: .cancel)
                }
                clearTapSequence()
                return Result()
            }
            guard event == .flagsChanged else { return Result() }
            if !held && keyCode != 63 { return Result() }
            let down = modifiers.contains(.fn)
            let wasHeld = held
            if down && modifiers != [.fn] {
                cancelGesture()
                suppressFnUntilRelease = true
                return Result(action: .cancel)
            }
            if down && !wasHeld {
                begin(at: timestamp)
                return Result(action: .start)
            }
            if !down && wasHeld { return Result(action: finish(at: timestamp)) }
            return Result()
        }
        if event == .keyUp && keyCode == shortcut.keyCode && suppressKeyUp {
            let result = Result(action: held ? finish(at: timestamp) : .none, consume: true)
            suppressKeyUp = false
            return result
        }
        if event == .keyDown && keyCode == shortcut.keyCode && suppressKeyUp {
            return Result(consume: true)
        }
        if held {
            if event == .flagsChanged && modifiers != shortcut.modifiers {
                // Releasing any required modifier finishes; adding an unrelated one cancels.
                if modifiers.subtracting(shortcut.modifiers).isEmpty {
                    return Result(action: finish(at: timestamp))
                }
                cancelGesture()
                return Result(action: .cancel)
            }
            if event == .keyDown { cancelGesture(); return Result(action: .cancel) }
        }
        if event == .keyDown && !repeating && !suppressKeyUp && keyCode == shortcut.keyCode && modifiers == shortcut.modifiers {
            begin(at: timestamp)
            suppressKeyUp = true
            return Result(action: .start, consume: true)
        }
        if event == .keyDown && !repeating { clearTapSequence() }
        return Result()
    }

    private mutating func begin(at timestamp: TimeInterval) {
        held = true
        pressedAt = timestamp
        if let lastShortReleaseAt {
            doubleTapCandidate = timestamp >= lastShortReleaseAt
                && timestamp - lastShortReleaseAt <= Self.doubleTapMaximumInterval
        } else {
            doubleTapCandidate = false
        }
    }

    private mutating func finish(at timestamp: TimeInterval) -> Action {
        let duration = max(0, timestamp - (pressedAt ?? timestamp))
        held = false
        pressedAt = nil
        if duration <= Self.shortTapMaximumDuration {
            if doubleTapCandidate {
                clearTapSequence()
                return .doubleTap
            }
            doubleTapCandidate = false
            lastShortReleaseAt = timestamp
            return .discardTap
        }
        clearTapSequence()
        return .stop
    }

    private mutating func cancelGesture() {
        held = false
        pressedAt = nil
        clearTapSequence()
    }

    private mutating func clearTapSequence() {
        doubleTapCandidate = false
        lastShortReleaseAt = nil
    }

    private mutating func expireTapSequence(at timestamp: TimeInterval) {
        guard !held else { return }
        guard let lastShortReleaseAt,
              timestamp < lastShortReleaseAt || timestamp - lastShortReleaseAt > Self.doubleTapMaximumInterval else { return }
        clearTapSequence()
    }
}
