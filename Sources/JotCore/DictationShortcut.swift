import Foundation

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
