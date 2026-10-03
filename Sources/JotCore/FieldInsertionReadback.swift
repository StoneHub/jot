import ApplicationServices
import Foundation

/// A write is verified only by the expected field change. Ambiguous writes never
/// trigger a second insertion; Electron's acknowledged-but-unchanged setter may.
public enum FieldInsertionReadback: Equatable, Sendable {
    case verified, unchanged, changed, unknown

    public func allowsAccessibilityRetry(after result: AXError) -> Bool {
        switch self {
        case .verified, .changed: return false
        case .unknown: return result == .attributeUnsupported || result == .notImplemented
        case .unchanged: return result == .success || result == .attributeUnsupported || result == .notImplemented
        }
    }

    public static func compare(_ before: FieldInsertionSnapshot, _ after: FieldInsertionSnapshot, inserted text: String, requireValue: Bool = false) -> FieldInsertionReadback {
        if requireValue && (before.value == nil || after.value == nil) { return .unknown }
        if let original = before.value, let actual = after.value {
            if let range = before.selection,
               range.location >= 0, range.length >= 0,
               range.location <= (original as NSString).length,
               range.length <= (original as NSString).length - range.location {
                let expected = (original as NSString).replacingCharacters(
                    in: NSRange(location: range.location, length: range.length), with: text)
                if actual == expected { return .verified }
            }
            if actual != original { return .changed }
            if let old = before.selection, let new = after.selection,
               old.location != new.location || old.length != new.length { return .changed }
            return .unchanged
        }
        if let old = before.selection, let new = after.selection {
            let length = (text as NSString).length
            if old.location >= 0, old.location <= Int.max - length,
               new.location == old.location + length && new.length == 0,
               new.location != old.location || new.length != old.length { return .verified }
            return old.location == new.location && old.length == new.length ? .unchanged : .changed
        }
        return .unknown
    }

}
