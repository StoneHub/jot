import AppKit
import ApplicationServices
import JotCore

/// Reads the captured field again on any thread. Every call goes to a fresh element reference with a short timeout, so a
/// slow app costs milliseconds per attribute rather than the six-second default, and the reference insertion uses keeps
/// its own timeout. A top-level type, so nothing about it is main-actor isolated; `@unchecked` because `AXUIElement` is a
/// thread-safe CF object the compiler cannot vouch for.
struct SuggestionFieldReader: @unchecked Sendable {
    let pid: pid_t
    let field: AXUIElement
    let knownHint: (value: String, hint: String?)?
    let primaryScreenHeight: CGFloat
    private static let timeout: Float = 0.005

    /// Nil when the focused element is not the captured field, is no longer editable, or reports no text or selection.
    func read() -> SuggestionFieldReadback? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        guard let current = DictationInput.focusedField(application), CFEqual(current, field) else { return nil }
        AXUIElementSetMessagingTimeout(current, Self.timeout)
        guard (try? DictationInput.validateEditable(current)) != nil,
              let role = DictationInput.stringAttribute(current, kAXRoleAttribute),
              let value = DictationInput.stringAttribute(current, kAXValueAttribute),
              let selection = DictationInput.selectedRange(of: current) else { return nil }
        let placeholder = DictationInput.stringAttribute(current, kAXPlaceholderValueAttribute)
        let hint: String?
        if value.isEmpty { hint = nil }
        else if let knownHint, knownHint.value == value { hint = knownHint.hint }
        else { hint = DictationInput.drawnHint(in: current, value: value) }
        let draft: SuggestionDraftSnapshot?
        if hint != nil {
            // A hint drawn inside a web editor is not the user's text, whatever character count the host reports.
            draft = SuggestionDraftSnapshot(value: "", location: 0, length: 0)
        } else {
            var countValue: CFTypeRef?
            let count: Int? = AXUIElementCopyAttributeValue(current, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success
                ? (countValue as? NSNumber)?.intValue : nil
            draft = SuggestionDraftSnapshot.accessibilityDraft(value: value, placeholder: placeholder, characterCount: count,
                                                               location: selection.location, length: selection.length)
        }
        guard let draft else { return nil }
        return SuggestionFieldReadback(draft: draft, role: role, placeholder: placeholder ?? hint,
                                       frame: DictationInput.frame(of: current, primaryScreenHeight: primaryScreenHeight),
                                       value: value, drawnHint: hint)
    }
}
