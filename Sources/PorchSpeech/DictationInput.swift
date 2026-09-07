import AppKit
import ApplicationServices

/// A listen-only Fn shortcut and a focus-bound text delivery transaction.
/// Enabling this component does not request permissions or alter macOS shortcuts.
@MainActor
final class DictationInput {
    enum InputError: LocalizedError {
        case accessibilityRequired, eventTapUnavailable, noTextField, secureField
        case targetChanged, shortcutCancelled, clipboardUnavailable, pasteUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Allow Accessibility access to use Fn dictation."
            case .eventTapUnavailable: return "The Fn listener could not start. Check Input Monitoring permission."
            case .noTextField: return "Focus an editable text field before holding Fn."
            case .secureField: return "Dictation is unavailable in password fields."
            case .targetChanged: return "Dictation cancelled because the focused application or text field changed."
            case .shortcutCancelled: return "Dictation cancelled because Fn was used with another key."
            case .clipboardUnavailable: return "The clipboard could not be preserved; no text was pasted."
            case .pasteUnavailable: return "The paste shortcut could not be created."
            }
        }
    }

    var onError: ((Error) -> Void)?
    struct DeliveryResult: Codable {
        let verified: Bool
        let path: String
        let outcome: String
        let targetApp: String
        let targetPID: Int32
        let role: String
        let subrole: String?

        var metadata: [String: Any] {
            var value: [String: Any] = ["verified": verified, "path": path, "outcome": outcome,
                "targetApp": targetApp, "targetPID": targetPID, "role": role]
            if let subrole { value["subrole"] = subrole }
            return value
        }
    }
    private(set) var lastDelivery: DeliveryResult?
    /// The owner can reject another Fn press while an earlier utterance is transcribing.
    var canStart: () -> Bool = { true }
    private(set) var isEnabled = false
    private let onStart: () -> Void
    private let onStop: () -> Void
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var focusObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var target: Target?
    private var fnDown = false
    private var recording = false
    private var clipboardRestore: (() -> Void)?
    private var pasteGeneration = 0
    private var targetGeneration = 0
    private static let pasteEventMarker: Int64 = 0x50534F524348

    private struct Target {
        let pid: pid_t
        let field: AXUIElement
    }

    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
    }

    deinit {
        // The C callbacks hold an unretained context; remove their sources before
        // this instance can disappear even if its owner forgot to call disable().
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        clipboardRestore?()
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard Self.accessibilityGranted else {
            onError?(InputError.accessibilityRequired)
            return false
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<DictationInput>.fromOpaque(context).takeUnretainedValue()
                // This tap's source is installed only on the main run loop.
                MainActor.assumeIsolated { controller.handle(type, event: event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onError?(InputError.eventTapUnavailable)
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }
        isEnabled = true
        return true
    }

    func disable() {
        isEnabled = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventTap = nil
        eventSource = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        fnDown = false
        clearTarget()
        if recording { recording = false; onStop() }
        clipboardRestore?()
        clipboardRestore = nil
    }

    /// May also be used by a separate explicit dictation command.
    func captureTarget() throws {
        clearTarget()
        guard Self.accessibilityGranted else { throw InputError.accessibilityRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw InputError.noTextField
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let field = focusedField(application) else { throw InputError.noTextField }
        try validateEditable(field)
        target = Target(pid: app.processIdentifier, field: field)
        observeFocus(application, pid: app.processIdentifier)
    }

    /// Ends a service-cancelled or empty utterance without calling its callbacks again.
    /// Keeps the physical Fn state so holding the key cannot accidentally restart capture.
    func discardTarget() {
        recording = false
        clearTarget()
    }

    /// Never equates a successful AX call or dispatched shortcut with verified insertion.
    /// Field contents are used transiently for verification and never included in diagnostics.
    func insert(_ text: String) async throws -> DeliveryResult {
        guard let target else { throw InputError.targetChanged }
        let generation = targetGeneration
        var path = "accessibility"
        defer { if targetGeneration == generation { clearTarget() } }
        do {
            try validateTransaction(target, generation: generation)
            guard !text.isEmpty else { return delivery(target, path: "none", outcome: "empty", verified: false) }
            let before = snapshot(target.field)
            var writable = DarwinBoolean(false)
            var attemptedAX = false
            let selectionAttribute = kAXSelectedTextAttribute as CFString
            if AXUIElementIsAttributeSettable(target.field, selectionAttribute, &writable) == .success,
               writable.boolValue {
                attemptedAX = true
                let result = AXUIElementSetAttributeValue(target.field, selectionAttribute, text as CFString)
                // Electron may report AX success while ignoring the setter. Give its
                // accessibility tree a turn, then inspect what actually changed.
                try await Task.sleep(nanoseconds: 70_000_000)
                try validateTransaction(target, generation: generation)
                switch compare(before, snapshot(target.field), inserted: text) {
                case .verified: return delivery(target, path: path, outcome: "verified", verified: true)
                case .changed:
                    return delivery(target, path: path, outcome: "changed_unverified_no_retry", verified: false)
                case .unknown where result == .success:
                    return delivery(target, path: path, outcome: "ax_success_readback_unavailable_no_retry", verified: false)
                default: break
                }
            }
            path = "clipboard_hid"
            // Use a fresh snapshot; do not overwrite a user's edit made while AX settled.
            try validateTransaction(target, generation: generation)
            let pasteBefore = snapshot(target.field)
            if attemptedAX {
                switch compare(before, pasteBefore, inserted: text) {
                case .verified: return delivery(target, path: "accessibility", outcome: "verified", verified: true)
                case .changed: return delivery(target, path: "accessibility", outcome: "changed_unverified_no_retry", verified: false)
                default: break
                }
            }
            try paste(text, into: target)
            for delay in [70_000_000, 130_000_000, 250_000_000, 300_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: delay)
                try validateTransaction(target, generation: generation)
                switch compare(pasteBefore, snapshot(target.field), inserted: text) {
                case .verified: return delivery(target, path: path, outcome: "verified", verified: true)
                case .changed: return delivery(target, path: path, outcome: "changed_unverified_no_retry", verified: false)
                case .unchanged, .unknown: break
                }
            }
            return delivery(target, path: path, outcome: "dispatched_not_verified", verified: false)
        } catch {
            _ = delivery(target, path: path, outcome: "cancelled_or_failed", verified: false)
            throw error
        }
    }

    private struct FieldSnapshot {
        let value: String?
        let selection: CFRange?
    }

    private enum Readback { case verified, unchanged, changed, unknown }

    private func snapshot(_ field: AXUIElement) -> FieldSnapshot {
        let value = stringAttribute(field, kAXValueAttribute)
        var raw: CFTypeRef?
        var selection: CFRange?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
           let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) { selection = range }
        }
        return FieldSnapshot(value: value, selection: selection)
    }

    private func compare(_ before: FieldSnapshot, _ after: FieldSnapshot, inserted text: String) -> Readback {
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

    private func validateTransaction(_ target: Target, generation: Int) throws {
        guard targetGeneration == generation else { throw InputError.targetChanged }
        try validateCurrent(target)
    }

    @discardableResult
    private func delivery(_ target: Target, path: String, outcome: String, verified: Bool) -> DeliveryResult {
        let app = NSRunningApplication(processIdentifier: target.pid)
        let result = DeliveryResult(verified: verified, path: path, outcome: outcome,
            targetApp: app?.bundleIdentifier ?? app?.localizedName ?? "unknown", targetPID: target.pid,
            role: stringAttribute(target.field, kAXRoleAttribute) ?? "unknown",
            subrole: stringAttribute(target.field, kAXSubroleAttribute))
        lastDelivery = result
        return result
    }

    private func handle(_ type: CGEventType, event: CGEvent) {
        guard isEnabled else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel(InputError.shortcutCancelled)
            fnDown = false
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        let down = event.flags.contains(.maskSecondaryFn)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if type == .keyDown {
            if event.getIntegerValueField(.eventSourceUserData) == Self.pasteEventMarker { return }
            if fnDown { cancel(InputError.shortcutCancelled) }
            return
        }
        guard type == .flagsChanged else { return }
        // Dedicated Fn/Globe is virtual key 63. Arrow/navigation events can also
        // carry secondaryFn, so their modifier flags must not start dictation.
        if !fnDown && event.getIntegerValueField(.keyboardEventKeycode) != 63 { return }
        let wasDown = fnDown
        fnDown = down
        if down && !event.flags.intersection(modifiers).isEmpty {
            cancel(InputError.shortcutCancelled)
            return
        }
        if down && !wasDown {
            guard canStart() else { return }
            do {
                try captureTarget()
                recording = true
                onStart()
            } catch { onError?(error) }
        } else if !down && wasDown && recording {
            recording = false
            checkFocus()
            onStop()
        }
    }

    private func cancel(_ error: Error) {
        guard target != nil || recording else { return }
        clearTarget()
        let wasRecording = recording
        recording = false
        onError?(error)
        if wasRecording { onStop() }
    }

    private func checkFocus() {
        guard let target else { return }
        do { try validateCurrent(target) }
        catch { cancel(error) }
    }

    private func focusedField(_ application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ field: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func validateEditable(_ field: AXUIElement) throws {
        let role = stringAttribute(field, kAXRoleAttribute)
        let subrole = stringAttribute(field, kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole || subrole?.localizedCaseInsensitiveContains("secure") == true {
            throw InputError.secureField
        }
        // Unknown/custom accessibility roles fail closed. Text-entry support varies by app.
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole else {
            throw InputError.noTextField
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &value) == .success,
           let enabled = value as? Bool, !enabled { throw InputError.noTextField }
    }

    private func validateCurrent(_ target: Target) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = focusedField(AXUIElementCreateApplication(target.pid)),
              CFEqual(current, target.field) else { throw InputError.targetChanged }
        try validateEditable(current)
    }

    private func observeFocus(_ application: AXUIElement, pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let controller = Unmanaged<DictationInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.checkFocus() }
        }, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            _ = AXObserverAddNotification(observer, application, notification as CFString, context)
        }
        focusObserver = observer
        observedApplication = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func clearTarget() {
        targetGeneration += 1
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
            if let observedApplication {
                for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
                    _ = AXObserverRemoveNotification(focusObserver, observedApplication, notification as CFString)
                }
            }
        }
        focusObserver = nil
        observedApplication = nil
        target = nil
    }

    private func paste(_ text: String, into target: Target) throws {
        clipboardRestore?()
        clipboardRestore = nil
        pasteGeneration += 1
        let generation = pasteGeneration
        let clipboard = NSPasteboard.general
        let originalChangeCount = clipboard.changeCount
        let saved: [[NSPasteboard.PasteboardType: Data]] = try (clipboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw InputError.clipboardUnavailable }
                values[type] = data
            }
            return values
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw InputError.pasteUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
        try validateCurrent(target)
        guard clipboard.changeCount == originalChangeCount else { throw InputError.clipboardUnavailable }
        clipboard.clearContents()
        let wroteText = clipboard.setString(text, forType: .string)
        let ownedChangeCount = clipboard.changeCount
        let restore = {
            // Never overwrite something the user or another app copied after this paste.
            guard clipboard.changeCount == ownedChangeCount else { return }
            clipboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }
        guard wroteText else { restore(); throw InputError.clipboardUnavailable }
        do { try validateCurrent(target) }
        catch { restore(); throw error }
        // Electron apps can ignore PID-directed keyboard events. Normal HID routing
        // reaches the currently focused editor, which was checked immediately above.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        clipboardRestore = restore
        // macOS has no paste-consumed acknowledgement. Allow the target to consume all
        // clipboard types before restoring, without blocking the microphone/UI thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            restore()
            if self?.pasteGeneration == generation { self?.clipboardRestore = nil }
        }
    }
}
