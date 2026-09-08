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
        guard let data = defaults.data(forKey: "dictationShortcut"),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data), value.isValid else { return .fn }
        return value
    }
    public func save(_ value: DictationShortcut) throws {
        guard value.isValid else { throw NSError(domain: "JotShortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose Fn or a key with Control, Option, or Command."]) }
        defaults.set(try JSONEncoder().encode(value), forKey: "dictationShortcut")
    }
}

/// Physical-key state is separate from capture state: repeats cannot restart an utterance,
/// and the trigger's key-up remains consumed even when its modifiers were released first.
public struct ShortcutTracker {
    public enum Event { case keyDown, keyUp, flagsChanged }
    public enum Action: Equatable { case none, start, stop, cancel }
    public struct Result: Equatable {
        public var action: Action = .none
        public var consume = false
    }
    private var held = false
    private var suppressKeyUp = false
    public init() {}
    public mutating func reset() { held = false; suppressKeyUp = false }

    public mutating func handle(_ event: Event, keyCode: UInt16, modifiers: ShortcutModifiers,
                                repeating: Bool = false, shortcut: DictationShortcut) -> Result {
        if shortcut.keyCode == nil {
            if event == .keyDown { return Result(action: held ? .cancel : .none) }
            guard event == .flagsChanged else { return Result() }
            if !held && keyCode != 63 { return Result() }
            let down = modifiers.contains(.fn)
            let wasHeld = held
            held = down
            if down && modifiers != [.fn] { return Result(action: .cancel) }
            if down && !wasHeld { return Result(action: .start) }
            if !down && wasHeld { return Result(action: .stop) }
            return Result()
        }
        if event == .keyUp && keyCode == shortcut.keyCode && suppressKeyUp {
            let result = Result(action: held ? .stop : .none, consume: true)
            held = false; suppressKeyUp = false
            return result
        }
        if event == .keyDown && keyCode == shortcut.keyCode && suppressKeyUp {
            return Result(consume: true)
        }
        if held {
            if event == .flagsChanged && modifiers != shortcut.modifiers {
                held = false
                // Releasing any required modifier finishes; adding an unrelated one cancels.
                return Result(action: modifiers.subtracting(shortcut.modifiers).isEmpty ? .stop : .cancel)
            }
            if event == .keyDown { held = false; return Result(action: .cancel) }
        }
        if event == .keyDown && !repeating && !suppressKeyUp && keyCode == shortcut.keyCode && modifiers == shortcut.modifiers {
            held = true; suppressKeyUp = true
            return Result(action: .start, consume: true)
        }
        return Result()
    }
}
