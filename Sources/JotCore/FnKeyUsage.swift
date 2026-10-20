import Foundation

/// What macOS itself does when Fn/Globe is pressed: System Settings → Keyboard → "Press 🌐 key to", stored as
/// `AppleFnUsageType` in com.apple.HIToolbox. Anything but Do Nothing also fires on every Fn dictation hold.
public enum FnKeyUsage: Int, Sendable {
    case nothing = 0, inputSource = 1, emoji = 2, dictation = 3

    /// Nil when macOS has no stored choice or an unknown one: no warning rather than a wrong one.
    public init?(storedValue: Any?) {
        guard let number = storedValue as? NSNumber else { return nil }
        self.init(rawValue: number.intValue)
    }

    /// What also happens on Fn, in words for "Fn also …"; nil when nothing does.
    public var conflict: String? {
        switch self {
        case .nothing: nil
        case .inputSource: "changes the input source"
        case .emoji: "opens Emoji & Symbols"
        case .dictation: "starts macOS Dictation"
        }
    }
}
