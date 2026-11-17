import AppKit
import ApplicationServices
import JotCore

/// Accessibility reads that run on any thread: the focused field, its attributes and frame, and whether Jot may write into it.
extension DictationInput {
    /// Electron honors AXManualAccessibility; native apps ignore it. Harmless to set every time an app comes to the front.
    nonisolated static func wakeAccessibility(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// An element's rectangle in AppKit coordinates, using the timeout already set on it. Nil when the app reports no usable size.
    nonisolated static func frame(of element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let rect = ScreenContextReader.frame(position: positionValue, size: sizeValue),
              rect.width > 1, rect.height > 1 else { return nil }
        // NSScreen.screens.first is the primary display, the one whose frame origin is (0, 0) and the one Accessibility measures from.
        return ScreenGeometry.appKitRect(accessibilityOrigin: rect.origin, size: rect.size, primaryScreenHeight: primaryScreenHeight)
    }

    nonisolated static func selectedRange(of field: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The focused element, a fresh reference with the default timeout; uses the timeout already set on `application`.
    nonisolated static func focusedField(_ application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    enum FocusRead {
        case element(AXUIElement), nothing, noAnswer
    }

    /// The focused element, nothing, or no answer within the timeout already set on `application`. Only a timeout
    /// (`cannotComplete`) is silence; any other failure reads as nothing focused, so it still ends a delivery.
    nonisolated static func focusRead(_ application: AXUIElement) -> FocusRead {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        if result == .cannotComplete { return .noAnswer }
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .nothing }
        return .element(value as! AXUIElement)
    }

    enum StringRead {
        case answered(String?), noAnswer
    }

    /// A string attribute, or no answer within the element's timeout. A missing or non-string value is an answer (nil).
    nonisolated static func stringRead(_ element: AXUIElement, _ name: String) -> StringRead {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .cannotComplete ? .noAnswer : .answered(result == .success ? value as? String : nil)
    }

    /// Bundle id of the process that owns an element, for the focused-field error and doctor output.
    nonisolated private static func owner(of field: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(field, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier ?? app?.localizedName ?? "pid \(pid)"
    }

    nonisolated static func stringAttribute(_ field: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func validateEditable(_ field: AXUIElement) throws {
        try validateEditable(field, role: stringAttribute(field, kAXRoleAttribute), subrole: stringAttribute(field, kAXSubroleAttribute))
    }

    /// The editable check with the role and subrole already read.
    nonisolated static func validateEditable(_ field: AXUIElement, role: String?, subrole: String?) throws {
        if subrole == kAXSecureTextFieldSubrole || subrole?.localizedCaseInsensitiveContains("secure") == true {
            throw InputError.secureField
        }
        // Unknown/custom accessibility roles fail closed. Text-entry support varies by app.
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole else {
            throw InputError.noTextField(app: owner(of: field), role: [role, subrole].compactMap { $0 }.joined(separator: "/").ifEmpty("no role"))
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &value) == .success,
           let enabled = value as? Bool, !enabled { throw InputError.noTextField(app: owner(of: field), role: "\(role ?? "field") (disabled)") }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
