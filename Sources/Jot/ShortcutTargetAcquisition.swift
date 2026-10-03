import ApplicationServices

/// Accessibility work for a shortcut press. Each lookup uses short AX timeouts;
/// the Electron retry waits asynchronously so neither the tap nor main run loop sleeps.
struct ShortcutTargetAcquisition {
    let pid: pid_t
    let appName: String

    func acquire() async throws -> AccessibilityElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        do { return AccessibilityElement(value: try focusedEditable(in: application)) }
        catch DictationInput.InputError.noTextField {
            DictationInput.wakeAccessibility(pid)
            try await Task.sleep(nanoseconds: 250_000_000)
            return AccessibilityElement(value: try focusedEditable(in: application))
        }
    }

    private func focusedEditable(in application: AXUIElement) throws -> AXUIElement {
        guard let field = DictationInput.focusedField(application) else {
            throw DictationInput.InputError.noTextField(app: appName, role: "no focused element")
        }
        AXUIElementSetMessagingTimeout(field, 0.05)
        try DictationInput.validateEditable(field)
        AXUIElementSetMessagingTimeout(field, 0.005)
        return field
    }
}
