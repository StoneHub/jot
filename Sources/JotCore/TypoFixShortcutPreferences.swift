import Foundation

/// The Fix typos shortcut: Control-Option-Space until the user picks another.
public final class TypoFixShortcutPreferences {
    public static let standard = DictationShortcut(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> DictationShortcut {
        guard let data = defaults.data(forKey: JotDefaultsKey.typoFixShortcut),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              value.isValid, value.keyCode != nil else { return Self.standard }
        return value
    }

    /// `others` are the dictation and suggestion shortcuts, which this one must not repeat.
    public func save(_ shortcut: DictationShortcut, others: [DictationShortcut?]) throws {
        guard shortcut.isValid, shortcut.keyCode != nil else {
            throw NSError(domain: "JotShortcut", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose a key with Control, Option, or Command."])
        }
        guard !others.contains(where: { Self.same($0, shortcut) }) else {
            throw NSError(domain: "JotShortcut", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a key different from the dictation and suggestion shortcuts."])
        }
        if shortcut == Self.standard { defaults.removeObject(forKey: JotDefaultsKey.typoFixShortcut) }
        else { defaults.set(try JSONEncoder().encode(shortcut), forKey: JotDefaultsKey.typoFixShortcut) }
    }

    /// The shortcut to listen for, or nil while it would take a key another shortcut uses.
    public static func effective(_ shortcut: DictationShortcut, others: [DictationShortcut?]) -> DictationShortcut? {
        others.contains { same($0, shortcut) } ? nil : shortcut
    }

    static func same(_ a: DictationShortcut?, _ b: DictationShortcut) -> Bool {
        guard let a, a.keyCode != nil else { return false }
        return a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }
}
