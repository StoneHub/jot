import Foundation

/// Exact UTF-16 field state used only for transient delivery verification.
public struct FieldInsertionSnapshot: Sendable {
    public let value: String?
    public let selection: NSRange?
    public init(value: String?, selection: NSRange?) { self.value = value; self.selection = selection }
}
