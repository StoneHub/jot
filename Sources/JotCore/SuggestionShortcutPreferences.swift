import Foundation

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
