import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public static let fn = Self(rawValue: 16)
}

public struct DictationShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt16?
    public let modifiers: ShortcutModifiers
    public let keyLabel: String
    public static let fn = Self(keyCode: nil, modifiers: [], keyLabel: "Fn")
    public init(keyCode: UInt16?, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public var isValid: Bool {
        guard let keyCode else { return modifiers.isEmpty && keyLabel == "Fn" }
        let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return keyCode <= 126 && keyCode != 53 && !modifierKeys.contains(keyCode)
            && !modifiers.intersection([.control, .option, .command]).isEmpty
            && modifiers.rawValue & ~UInt8(15) == 0
            && !keyLabel.isEmpty && keyLabel.count <= 20
            && keyLabel.rangeOfCharacter(from: .controlCharacters) == nil
    }
    public var displayName: String {
        guard keyCode != nil else { return "Fn" }
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "") + keyLabel
    }
}

public final class ShortcutPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> DictationShortcut {
        guard let data = defaults.data(forKey: JotDefaultsKey.dictationShortcut),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data), value.isValid else { return .fn }
        return value
    }
    public func save(_ value: DictationShortcut) throws {
        guard value.isValid else { throw NSError(domain: "JotShortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose Fn or a key with Control, Option, or Command."]) }
        defaults.set(try JSONEncoder().encode(value), forKey: JotDefaultsKey.dictationShortcut)
    }
}

/// Physical-key state is separate from capture state: repeats cannot restart an utterance,
/// and the trigger's key-up remains consumed even when its modifiers were released first.
public struct ShortcutTracker {
    public enum Event { case keyDown, keyUp, flagsChanged }
    public enum Action: Equatable { case none, start, stop, discardTap, recover, cancel }
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
    private var recoveryCandidate = false
    private var lastShortReleaseAt: TimeInterval?
    public init() {}
    public mutating func reset() {
        held = false
        suppressKeyUp = false
        suppressFnUntilRelease = false
        pressedAt = nil
        recoveryCandidate = false
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
                // Some keyboards emit a key event as well as the Fn flags event. It is
                // not a second press and must not cancel or restart the held gesture.
                if keyCode == 63 { return Result() }
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
            recoveryCandidate = timestamp >= lastShortReleaseAt
                && timestamp - lastShortReleaseAt <= Self.doubleTapMaximumInterval
        } else {
            recoveryCandidate = false
        }
    }

    private mutating func finish(at timestamp: TimeInterval) -> Action {
        let duration = max(0, timestamp - (pressedAt ?? timestamp))
        held = false
        pressedAt = nil
        if duration <= Self.shortTapMaximumDuration {
            if recoveryCandidate {
                clearTapSequence()
                return .recover
            }
            recoveryCandidate = false
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
        recoveryCandidate = false
        lastShortReleaseAt = nil
    }

    private mutating func expireTapSequence(at timestamp: TimeInterval) {
        guard !held else { return }
        guard let lastShortReleaseAt,
              timestamp < lastShortReleaseAt || timestamp - lastShortReleaseAt > Self.doubleTapMaximumInterval else { return }
        clearTapSequence()
    }
}
