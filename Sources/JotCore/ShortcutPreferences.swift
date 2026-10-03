import Foundation

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
