import AppKit
import ApplicationServices
import JotCore

/// A global push-to-talk shortcut and a focus-bound text delivery transaction.
/// Enabling this component does not request permissions or alter macOS shortcuts.
@MainActor
final class DictationInput {
    enum InputError: LocalizedError {
        case accessibilityRequired, eventTapUnavailable, secureField
        case noTextField(app: String, role: String)
        case targetChanged, shortcutCancelled, clipboardUnavailable, pasteUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Allow Accessibility access to use dictation."
            case .eventTapUnavailable: return "The shortcut listener could not start. Check Input Monitoring permission."
            case .noTextField(let app, let role): return "Focus an editable text field before holding the dictation shortcut. Jot saw \(role) in \(app)."
            case .secureField: return "Dictation is unavailable in password fields."
            case .targetChanged: return "Dictation cancelled because the focused application or text field changed."
            case .shortcutCancelled: return "Dictation cancelled because the dictation shortcut was used with another key."
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
    /// The owner can reject another shortcut press while an earlier utterance is transcribing.
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
    var shortcut: DictationShortcut = .fn { didSet { tracker.reset() } }
    var isRecordingShortcut = false { didSet { tracker.reset() } }
    private var tracker = ShortcutTracker()
    private var shortcutPresses = 0
    private var fnPresses = 0
    private var acceptedPresses = 0
    private var busyPresses = 0
    private var lastShortcutError: String?
    /// Kept after a later press succeeds, so a rejection in one app survives a success in another.
    private var lastRejection: String?
    /// Health and counts only. Never includes typed text or accessibility field values.
    var diagnostics: [String: Any] {
        var result: [String: Any] = [
            "shortcut": shortcut.displayName, "shortcutPresses": shortcutPresses, "enabled": isEnabled,
            "eventTapEnabled": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            "fnPresses": fnPresses, "acceptedPresses": acceptedPresses,
            "busyPresses": busyPresses]
        if let lastShortcutError { result["lastError"] = lastShortcutError }
        if let lastRejection { result["lastRejection"] = lastRejection }
        return result
    }

    private func report(_ error: Error) {
        lastShortcutError = error.localizedDescription
        lastRejection = error.localizedDescription
        onError?(error)
    }

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
            report(InputError.accessibilityRequired)
            return false
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<DictationInput>.fromOpaque(context).takeUnretainedValue()
                // This tap's source is installed only on the main run loop.
                let consume = MainActor.assumeIsolated { controller.handle(type, event: event) }
                return consume ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            report(InputError.eventTapUnavailable)
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
            MainActor.assumeIsolated {
                if let front = NSWorkspace.shared.frontmostApplication { Self.wakeAccessibility(front.processIdentifier) }
                self?.checkFocus()
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { Self.wakeAccessibility(front.processIdentifier) }
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
        tracker.reset()
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
            throw InputError.noTextField(app: "no other app in front", role: "none")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let field = try editableField(in: application, of: app)
        target = Target(pid: app.processIdentifier, field: field)
        observeFocus(application, pid: app.processIdentifier)
    }

    /// Electron and Chromium apps keep their accessibility tree off until asked. The first failed look wakes it and looks once more.
    private func editableField(in application: AXUIElement, of app: NSRunningApplication) throws -> AXUIElement {
        let name = app.bundleIdentifier ?? app.localizedName ?? "unknown app"
        do {
            guard let field = focusedField(application) else { throw InputError.noTextField(app: name, role: "no focused element") }
            try validateEditable(field)
            return field
        } catch InputError.noTextField {
            Self.wakeAccessibility(app.processIdentifier)
            usleep(250_000)
            guard let field = focusedField(application) else { throw InputError.noTextField(app: name, role: "no focused element") }
            try validateEditable(field)
            return field
        }
    }

    /// Electron honors AXManualAccessibility; native apps ignore it. Harmless to set every time an app comes to the front.
    static func wakeAccessibility(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Ends a service-cancelled or empty utterance without calling its callbacks again.
    /// Keeps the physical shortcut state so holding the key cannot accidentally restart capture.
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

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isEnabled else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel(InputError.shortcutCancelled)
            tracker.reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        guard !isRecordingShortcut else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == Self.pasteEventMarker { return false }
        let kind: ShortcutTracker.Event
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return false
        }
        let result = tracker.handle(kind, keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: shortcut.keyCode == nil ? ShortcutModifiers(event.flags) : ShortcutModifiers(event.flags).subtracting(.fn), repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            shortcut: shortcut)
        switch result.action {
        case .start:
            shortcutPresses += 1
            if shortcut.keyCode == nil { fnPresses += 1 }
            guard canStart() else { busyPresses += 1; return result.consume }
            do {
                try captureTarget()
                recording = true
                acceptedPresses += 1
                lastShortcutError = nil
                onStart()
            } catch { report(error) }
        case .stop:
            if recording {
                recording = false
                checkFocus()
                onStop()
            }
        case .cancel: cancel(InputError.shortcutCancelled)
        case .none: break
        }
        return result.consume
    }

    private func cancel(_ error: Error) {
        guard target != nil || recording else { return }
        clearTarget()
        let wasRecording = recording
        recording = false
        report(error)
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

    /// Bundle id of the process that owns an element, for the focused-field error and doctor output.
    private func owner(of field: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(field, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier ?? app?.localizedName ?? "pid \(pid)"
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
            throw InputError.noTextField(app: owner(of: field), role: [role, subrole].compactMap { $0 }.joined(separator: "/").ifEmpty("no role"))
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &value) == .success,
           let enabled = value as? Bool, !enabled { throw InputError.noTextField(app: owner(of: field), role: "\(role ?? "field") (disabled)") }
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

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
