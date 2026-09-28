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
        case targetChanged, shortcutCancelled, pasteUnavailable, selectionUnavailable
        case pressIgnored(shortcut: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Allow Accessibility access to use dictation."
            case .eventTapUnavailable: return "The shortcut listener could not start. Check Input Monitoring permission."
            case .noTextField(let app, let role): return "Jot retained the speech, but did not find an editable field. Choose Review saved dictation in Jot to copy it. Jot saw \(role) in \(app)."
            case .secureField: return "Jot will not insert into password fields. Speech was retained. Choose Review saved dictation in Jot to copy it."
            case .targetChanged: return "Focus changed while Jot was listening. Speech was retained. Choose Review saved dictation in Jot to copy it."
            case .shortcutCancelled: return "The shortcut was released with another key. Speech was retained. Choose Review saved dictation in Jot to copy it."
            case .pasteUnavailable: return "The paste shortcut could not be created."
            case .selectionUnavailable: return "This field did not let Jot select your notes, so nothing was replaced."
            case .pressIgnored(let shortcut, let reason): return "\(shortcut) press ignored. \(reason)"
            }
        }
    }

    var onError: ((Error) -> Void)?
    var onDiscardTap: (() -> Void)?
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
    /// The owner rejects a shortcut press with the reason the notice should show, or nil to let it start.
    var startBlocker: () -> String? = { nil }
    private(set) var isEnabled = false
    private let onStart: () -> Void
    /// Called with the key event's own timestamp (system uptime), so a stalled main thread does not shorten the measured latency.
    private let onStop: (TimeInterval) -> Void
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?
    private var focusObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var target: Target?
    var shortcut: DictationShortcut = .fn { didSet { tracker.reset(); suggestionFn.reset() } }
    var isRecordingShortcut = false { didSet { tracker.reset(); suggestionFn.reset(); dismissSuggestionKeys() } }
    var dictationEnabled = true
    var suggestionShortcut: DictationShortcut?
    var fnSuggestionsEnabled = false { didSet { suggestionFn.reset() } }
    private var suggestionFn = SuggestionFnGesture()
    var suggestionAllowed: () -> Bool = { false }
    var onSuggestionRequest: (() -> Void)?
    /// A request the service cannot take right now, so the gesture is not a silent no-op.
    var onSuggestionRefused: (() -> Void)?
    var onSuggestionAccept: (() -> Void)?
    var onSuggestionDismiss: ((SuggestionHistoryEntry.Action) -> Void)?
    private var suggestionKeys = SuggestionKeyTracker()
    private var suggestionKeyRevision = 0
    var suggestionState: SuggestionKeyTracker.State { suggestionKeys.state }
    func showSuggestionKeys(_ state: SuggestionKeyTracker.State) { suggestionKeys.show(state) }
    func dismissSuggestionKeys() { suggestionKeys.dismiss() }

    private var tracker = ShortcutTracker()
    private var shortcutPresses = 0
    private var fnPresses = 0
    private var acceptedPresses = 0
    private var busyPresses = 0
    private var discardedTaps = 0
    private var targetCaptureFailures = 0
    private var lastShortcutError: String?
    /// Kept after a later press succeeds, so a rejection in one app survives a success in another.
    private var lastRejection: String?
    /// Health and counts only. Never includes typed text or accessibility field values.
    var diagnostics: [String: Any] {
        var result: [String: Any] = [
            "shortcut": shortcut.displayName, "shortcutPresses": shortcutPresses, "enabled": isEnabled,
            "eventTapEnabled": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            "fnPresses": fnPresses, "acceptedPresses": acceptedPresses,
            "busyPresses": busyPresses, "discardedTaps": discardedTaps,
            "targetCaptureFailures": targetCaptureFailures]
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
    /// Stays true through focus-error completion until the physical gesture ends.
    private var gestureAccepted = false
    private var clipboardRestore: (() -> Void)?
    private var pasteGeneration = 0
    private var targetGeneration = 0
    private static let pasteEventMarker: Int64 = 0x50534F524348

    private struct Target {
        let pid: pid_t
        let field: AXUIElement
    }

    init(onStart: @escaping () -> Void, onStop: @escaping (TimeInterval) -> Void) {
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
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
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
        // A drag or window click finishes an interactive screenshot; the keys after it belong to the field again.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.suggestionKeys.endScreenshot() }
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
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        tracker.reset()
        suggestionFn.reset()
        suggestionKeys.reset()
        onSuggestionDismiss?(.serviceStopped)
        gestureAccepted = false
        clearTarget()
        if recording { recording = false; onStop(ProcessInfo.processInfo.systemUptime) }
        clipboardRestore?()
        clipboardRestore = nil
    }

    /// May also be used by a separate explicit dictation command.
    func captureTarget(wakeRetry: Bool = true) throws {
        clearTarget()
        guard Self.accessibilityGranted else { throw InputError.accessibilityRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw InputError.noTextField(app: "no other app in front", role: "none")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if !wakeRetry { AXUIElementSetMessagingTimeout(application, 0.005) }
        let field = try editableField(in: application, of: app, wakeRetry: wakeRetry)
        target = Target(pid: app.processIdentifier, field: field)
        observeFocus(application, pid: app.processIdentifier)
    }

    /// Electron and Chromium apps keep their accessibility tree off until asked. The first failed look wakes it and looks once more.
    private func editableField(in application: AXUIElement, of app: NSRunningApplication, wakeRetry: Bool) throws -> AXUIElement {
        let name = app.bundleIdentifier ?? app.localizedName ?? "unknown app"
        do {
            guard let field = Self.focusedField(application) else { throw InputError.noTextField(app: name, role: "no focused element") }
            if !wakeRetry { AXUIElementSetMessagingTimeout(field, 0.005) }
            try Self.validateEditable(field)
            return field
        } catch InputError.noTextField {
            guard wakeRetry else { throw InputError.noTextField(app: name, role: "unavailable text field") }
            Self.wakeAccessibility(app.processIdentifier)
            usleep(250_000)
            guard let field = Self.focusedField(application) else { throw InputError.noTextField(app: name, role: "no focused element") }
            try Self.validateEditable(field)
            return field
        }
    }

    /// Electron honors AXManualAccessibility; native apps ignore it. Harmless to set every time an app comes to the front.
    static func wakeAccessibility(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Screen rectangle of the captured field in AppKit coordinates, or nil when the app is not in front or does not report one.
    /// A busy target app must not be allowed to block the read for long.
    func targetFrame(timeout: Float = 0.1) -> CGRect? {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let primary = NSScreen.screens.first else { return nil }
        // The timeout lives on this element ref, which insert() also reads; it is reset before this synchronous call returns so insert() keeps the default.
        AXUIElementSetMessagingTimeout(target.field, timeout)
        defer { AXUIElementSetMessagingTimeout(target.field, 0) }
        return Self.frame(of: target.field, primaryScreenHeight: primary.frame.height)
    }

    /// An element's rectangle in AppKit coordinates, using the timeout already set on it. Nil when the app reports no usable size.
    nonisolated fileprivate static func frame(of element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let rect = ScreenContextReader.frame(position: positionValue, size: sizeValue),
              rect.width > 1, rect.height > 1 else { return nil }
        // NSScreen.screens.first is the primary display, the one whose frame origin is (0, 0) and the one Accessibility measures from.
        return ScreenGeometry.appKitRect(accessibilityOrigin: rect.origin, size: rect.size, primaryScreenHeight: primaryScreenHeight)
    }

    /// Ends a service-cancelled or empty utterance without calling its callbacks again.
    /// Keeps the physical shortcut state so holding the key cannot accidentally restart capture.
    func discardTarget() {
        recording = false
        clearTarget()
    }

    /// Never equates a successful AX call or dispatched shortcut with verified insertion.
    /// Field contents are used transiently for verification and never included in diagnostics.
    func insert(_ text: String, expected: SuggestionField? = nil) async throws -> DeliveryResult {
        guard let target else { throw InputError.targetChanged }
        let generation = targetGeneration
        var path = "accessibility"
        defer { if targetGeneration == generation { clearTarget() } }
        do {
            try validateTransaction(target, generation: generation)
            guard !text.isEmpty else { return delivery(target, path: "none", outcome: "empty", verified: false) }
            if let expected, !suggestionFieldIsCurrent(expected) { throw InputError.targetChanged }
            let before = snapshot(target.field, forSuggestion: expected != nil)
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
                switch compare(before, snapshot(target.field, forSuggestion: expected != nil), inserted: text, requireValue: expected != nil) {
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
            if let expected, !suggestionFieldIsCurrent(expected) { throw InputError.targetChanged }
            let pasteBefore = snapshot(target.field, forSuggestion: expected != nil)
            if attemptedAX {
                switch compare(before, pasteBefore, inserted: text, requireValue: expected != nil) {
                case .verified: return delivery(target, path: "accessibility", outcome: "verified", verified: true)
                case .changed: return delivery(target, path: "accessibility", outcome: "changed_unverified_no_retry", verified: false)
                default: break
                }
            }
            // Prefer direct text events. Clipboard fallback is safe only if no direct events were sent.
            path = try ClipboardInsertion.deliver(paste: {
                path = "clipboard_hid"
                try paste(text, into: target)
            }, type: {
                path = "unicode_hid"
                try typeUnicode(text, into: target, generation: generation)
            })
            for delay in [70_000_000, 130_000_000, 250_000_000, 300_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: delay)
                try validateTransaction(target, generation: generation)
                switch compare(pasteBefore, snapshot(target.field, forSuggestion: expected != nil), inserted: text, requireValue: expected != nil) {
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

    struct SuggestionField {
        let draft: SuggestionDraftSnapshot
        let bundleID: String
        let appName: String
        let role: String
        /// The AX placeholder, or hint text a web editor draws inside the field.
        let placeholder: String?
        fileprivate let generation: Int
        fileprivate let keyRevision: Int
    }

    /// The captured field as it is now, or nil when its app is not in front, focus moved, or it cannot be read safely.
    func readSuggestionField() -> SuggestionField? {
        guard let target, let reader = suggestionFieldReader(for: target), let readback = reader.read() else { return nil }
        drawnHint = (target.field, readback.value, readback.drawnHint)
        return suggestionField(from: readback, target: target)
    }

    /// The card's monitor: reads the captured field again off the main actor and returns where it is while it still holds
    /// the text, selection and hint the card was made from. Nil when focus, the field or its text changed, or the field
    /// reports no rectangle. Only the frontmost check and the comparison run on the main actor.
    func observeSuggestionField(_ expected: SuggestionField) async -> CGRect? {
        guard expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              let target, let reader = suggestionFieldReader(for: target) else { return nil }
        let pid = target.pid, field = target.field
        let readback = await Task.detached(priority: .userInitiated) { reader.read() }.value
        guard let readback, expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        drawnHint = (field, readback.value, readback.drawnHint)
        guard readback.draft == expected.draft, readback.role == expected.role, readback.placeholder == expected.placeholder,
              let frame = readback.frame else { return nil }
        return frame
    }

    private func suggestionFieldReader(for target: Target) -> SuggestionFieldReader? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid, let primary = NSScreen.screens.first else { return nil }
        return SuggestionFieldReader(pid: target.pid, field: target.field, knownHint: knownHint(for: target.field),
                                     primaryScreenHeight: primary.frame.height)
    }

    private func suggestionField(from readback: SuggestionFieldReadback, target: Target) -> SuggestionField? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), let bundle = app.bundleIdentifier else { return nil }
        return SuggestionField(draft: readback.draft, bundleID: bundle, appName: app.localizedName ?? bundle, role: readback.role,
                               placeholder: readback.placeholder, generation: targetGeneration, keyRevision: suggestionKeyRevision)
    }

    /// Draft acceptance: select exactly the notes the preview was made from, then insert over them through the
    /// verified path. Restores the selection and edits nothing when the field will not take that selection.
    func replace(_ seed: SuggestionSeed, with text: String, expected: SuggestionField) async throws -> DeliveryResult {
        let draft = expected.draft
        if seed.location == draft.location && seed.length == draft.length { return try await insert(text, expected: expected) }
        guard let target, suggestionFieldIsCurrent(expected) else { throw InputError.targetChanged }
        guard let selected = SuggestionDraftSnapshot(value: draft.value, location: seed.location, length: seed.length),
              selected.selectedText == seed.text else { throw InputError.targetChanged }
        let rangeAttribute = kAXSelectedTextRangeAttribute as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.field, rangeAttribute, &settable) == .success, settable.boolValue else {
            throw InputError.selectionUnavailable
        }
        func select(_ location: Int, _ length: Int) -> Bool {
            var range = CFRange(location: location, length: length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(target.field, rangeAttribute, value) == .success
        }
        let updated = SuggestionField(draft: selected, bundleID: expected.bundleID, appName: expected.appName, role: expected.role,
                                      placeholder: expected.placeholder, generation: expected.generation, keyRevision: expected.keyRevision)
        guard select(seed.location, seed.length) else { throw InputError.selectionUnavailable }
        try await Task.sleep(nanoseconds: 40_000_000)
        guard suggestionFieldIsCurrent(updated) else {
            // Only put the caret back while the text is still the user's original draft.
            if readSuggestionField()?.draft.value == draft.value { _ = select(draft.location, draft.length) }
            throw InputError.selectionUnavailable
        }
        return try await insert(text, expected: updated)
    }

    /// Reads the text around the captured field later, off the main thread. Only the field's frame and window are read here.
    func screenContextReader() -> ScreenContextReader? {
        guard let target else { return nil }
        AXUIElementSetMessagingTimeout(target.field, 0.005)
        defer { AXUIElementSetMessagingTimeout(target.field, 0) }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, windowValue: CFTypeRef?, parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.field, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(target.field, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let frame = ScreenContextReader.frame(position: positionValue, size: sizeValue),
              AXUIElementCopyAttributeValue(target.field, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
        var window: AXUIElement?
        if AXUIElementCopyAttributeValue(target.field, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            window = (windowValue as! AXUIElement)
        }
        return ScreenContextReader(field: target.field, fieldFrame: frame, parent: parentValue as! AXUIElement, window: window)
    }

    /// Where the captured field and its window are, for a suggestion's window image. Only frames are read, each with a
    /// short timeout; the image itself is taken later, off the main actor.
    func windowImageCapture() -> WindowImageCapture? {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return nil }
        AXUIElementSetMessagingTimeout(target.field, 0.005)
        defer { AXUIElementSetMessagingTimeout(target.field, 0) }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.field, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(target.field, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let field = ScreenContextReader.frame(position: positionValue, size: sizeValue) else { return nil }
        var windowFrame: CGRect?
        if AXUIElementCopyAttributeValue(target.field, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            let window = windowValue as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.005)
            var windowPosition: CFTypeRef?, windowSize: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &windowPosition) == .success,
               AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &windowSize) == .success {
                windowFrame = ScreenContextReader.frame(position: windowPosition, size: windowSize)
            }
        }
        return WindowImageCapture(pid: target.pid, window: windowFrame, field: field)
    }

    func suggestionFieldIsCurrent(_ expected: SuggestionField) -> Bool {
        guard expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              let current = readSuggestionField() else { return false }
        return current.generation == expected.generation && current.bundleID == expected.bundleID
            && current.role == expected.role && current.draft == expected.draft && current.placeholder == expected.placeholder
    }

    private struct FieldSnapshot {
        let value: String?
        let selection: CFRange?
    }

    private enum Readback { case verified, unchanged, changed, unknown }

    /// Last hint search, by field and exact reported value, so the card's 250 ms re-reads stay cheap.
    private var drawnHint: (field: AXUIElement, value: String, hint: String?)?

    private func knownHint(for field: AXUIElement) -> (value: String, hint: String?)? {
        guard let cached = drawnHint, CFEqual(cached.field, field) else { return nil }
        return (cached.value, cached.hint)
    }

    /// `drawnHint(in:value:)` through the cache above.
    private func hint(drawnIn field: AXUIElement, value: String) -> String? {
        if let cached = drawnHint, CFEqual(cached.field, field), cached.value == value { return cached.hint }
        let hint = Self.drawnHint(in: field, value: value)
        drawnHint = (field, value, hint)
        return hint
    }

    /// Hint text that a web editor draws inside the field and reports as its value, or nil when the value is the
    /// user's. Looks only a few levels into short values; see `FieldHint`. The field keeps its caller's timeout, which
    /// insertion relies on; descendants get a short one.
    nonisolated fileprivate static func drawnHint(in field: AXUIElement, value: String) -> String? {
        guard (value as NSString).length <= 200 else { return nil }
        var hints: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(field, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 24 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if depth > 0 { AXUIElementSetMessagingTimeout(element, 0.005) }
            var classes: CFTypeRef?
            if depth > 0, AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes) == .success,
               let names = classes as? [String], FieldHint.isHintClass(names) {
                let text = ScreenContextReader.staticText(under: element)
                if !text.isEmpty { hints.append(text) } else if let own = stringAttribute(element, kAXValueAttribute) { hints.append(own) }
                continue
            }
            if depth < 3 { queue += ScreenContextReader.children(of: element).prefix(8).map { (element: $0, depth: depth + 1) } }
        }
        return FieldHint.valueIsHint(value, hints: hints) ? hints.joined(separator: " ") : nil
    }

    nonisolated fileprivate static func selectedRange(of field: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    private func snapshot(_ field: AXUIElement, forSuggestion: Bool = false) -> FieldSnapshot {
        let value = Self.stringAttribute(field, kAXValueAttribute)
        let selection = Self.selectedRange(of: field)
        if forSuggestion {
            var countValue: CFTypeRef?
            let count: Int? = AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success
                ? (countValue as? NSNumber)?.intValue : nil
            guard let value, let selection else { return FieldSnapshot(value: nil, selection: nil) }
            // A hint drawn inside a web editor is not the user's text, whatever character count the host reports.
            if !value.isEmpty, hint(drawnIn: field, value: value) != nil {
                return FieldSnapshot(value: "", selection: CFRange(location: 0, length: 0))
            }
            guard let draft = SuggestionDraftSnapshot.accessibilityDraft(value: value,
                    placeholder: Self.stringAttribute(field, kAXPlaceholderValueAttribute), characterCount: count,
                    location: selection.location, length: selection.length) else {
                return FieldSnapshot(value: nil, selection: nil)
            }
            return FieldSnapshot(value: draft.value, selection: CFRange(location: draft.location, length: draft.length))
        }
        return FieldSnapshot(value: value, selection: selection)
    }

    private func compare(_ before: FieldSnapshot, _ after: FieldSnapshot, inserted text: String, requireValue: Bool = false) -> Readback {
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

    private func validateTransaction(_ target: Target, generation: Int) throws {
        guard targetGeneration == generation else { throw InputError.targetChanged }
        try validateCurrent(target)
    }

    @discardableResult
    private func delivery(_ target: Target, path: String, outcome: String, verified: Bool) -> DeliveryResult {
        let app = NSRunningApplication(processIdentifier: target.pid)
        let result = DeliveryResult(verified: verified, path: path, outcome: outcome,
            targetApp: app?.bundleIdentifier ?? app?.localizedName ?? "unknown", targetPID: target.pid,
            role: Self.stringAttribute(target.field, kAXRoleAttribute) ?? "unknown",
            subrole: Self.stringAttribute(target.field, kAXSubroleAttribute))
        lastDelivery = result
        return result
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isEnabled else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            suggestionKeys.reset()
            onSuggestionDismiss?(.serviceStopped)
            cancel(InputError.shortcutCancelled)
            gestureAccepted = false
            tracker.reset()
            suggestionFn.reset()
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
        let eventTimestamp = event.timestamp == 0
            ? ProcessInfo.processInfo.systemUptime
            : Double(event.timestamp) / 1_000_000_000
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Fn release can emit a second, non-text key pair (179 on this Mac).
        // Leave it to macOS, but do not invalidate the tap sequence or queued request.
        if ShortcutTracker.isFnCompanionEvent(kind, keyCode: keyCode) { return false }
        let modifiers = ShortcutModifiers(event.flags).subtracting(.fn)
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let allowed = !recording && suggestionAllowed()
        let suggestion = suggestionKeys.handle(kind, keyCode: keyCode, modifiers: modifiers, repeating: repeating,
                                              shortcut: suggestionShortcut, allowed: allowed, at: eventTimestamp)
        switch suggestion.action {
        case .request:
            scheduleSuggestionRequest()
        case .accept:
            Task { @MainActor [weak self] in
                guard let self, self.suggestionKeys.state == .accepting else { return }
                self.onSuggestionAccept?()
            }
        case .dismiss:
            suggestionKeyRevision += 1
            // No AX calls in this branch: acceptance checks this integer before any insertion.
            Task { @MainActor [weak self] in
                guard let self, self.suggestionKeys.state == .idle else { return }
                self.onSuggestionDismiss?(keyCode == 53 && modifiers.isEmpty ? .escape : .typedOver)
            }
        case .none: break
        }
        if suggestion.consume { return true }
        if kind == .keyDown && !suggestion.screenshot { suggestionKeyRevision += 1 }
        if let request = suggestionShortcut, request.keyCode == keyCode,
           request.modifiers == modifiers, !allowed {
            if kind == .keyDown && !repeating { onSuggestionRefused?() }
            return false
        }
        // While Fn dictation is held, the suggestion chord's modifiers must not cancel capture.
        if recording, shortcut.keyCode == nil, kind == .flagsChanged, event.flags.contains(.maskSecondaryFn),
           let request = suggestionShortcut, !modifiers.isEmpty,
           modifiers.subtracting(request.modifiers).isEmpty { return false }
        // Fn still requests suggestions when hold dictation is disabled or uses a different key.
        if !dictationEnabled || shortcut.keyCode != nil {
            if suggestionFn.handle(kind, keyCode: keyCode, modifiers: ShortcutModifiers(event.flags),
                                   at: eventTimestamp, enabled: fnSuggestionsEnabled) {
                if allowed { scheduleSuggestionRequest() } else { onSuggestionRefused?() }
            }
        }
        guard dictationEnabled else { return false }
        let result = tracker.handle(kind, keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: shortcut.keyCode == nil ? ShortcutModifiers(event.flags) : ShortcutModifiers(event.flags).subtracting(.fn), repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            shortcut: shortcut, at: eventTimestamp)
        switch result.action {
        case .start:
            onSuggestionDismiss?(.typedOver)
            shortcutPresses += 1
            if shortcut.keyCode == nil { fnPresses += 1 }
            if let reason = startBlocker() {
                gestureAccepted = false
                busyPresses += 1
                report(InputError.pressIgnored(shortcut: shortcut.displayName, reason: reason))
                return result.consume
            }
            gestureAccepted = true
            recording = true
            acceptedPresses += 1
            lastShortcutError = nil
            var targetError: Error?
            do {
                try captureTarget()
            } catch {
                targetCaptureFailures += 1
                targetError = error
            }
            // Capturing speech is useful even when there is not yet a safe insertion
            // target. The service retains that utterance for an explicit retry.
            onStart()
            if let targetError { report(targetError) }
        case .stop:
            if recording {
                recording = false
                checkFocus()
                onStop(eventTimestamp)
            }
            gestureAccepted = false
        case .discardTap:
            let acceptedTap = gestureAccepted
            gestureAccepted = false
            if acceptedTap {
                recording = false
                discardedTaps += 1
                clearTarget()
                onDiscardTap?()
            }
        case .doubleTap:
            // End the two short holds without ever interpreting them as recovery insertion.
            let acceptedTap = gestureAccepted
            gestureAccepted = false
            if acceptedTap {
                recording = false
                discardedTaps += 1
                clearTarget()
                onDiscardTap?()
            }
            if shortcut.keyCode == nil && fnSuggestionsEnabled {
                if suggestionAllowed() { scheduleSuggestionRequest() } else { onSuggestionRefused?() }
            }
        case .cancel:
            // A rejected busy press must not clear the target owned by pending work.
            if recording { cancel(InputError.shortcutCancelled) }
            gestureAccepted = false
        case .none: break
        }
        return result.consume
    }

    private func scheduleSuggestionRequest() {
        suggestionKeyRevision += 1
        let revision = suggestionKeyRevision
        let requestedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        suggestionKeys.show(.requesting)
        Task { @MainActor [weak self] in
            guard let self, self.suggestionKeys.state == .requesting,
                  self.suggestionKeyRevision == revision, self.suggestionAllowed(),
                  requestedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            self.onSuggestionRequest?()
        }
    }

    private func cancel(_ error: Error) {
        guard target != nil || recording else { return }
        clearTarget()
        let wasRecording = recording
        recording = false
        report(error)
        if wasRecording { onStop(ProcessInfo.processInfo.systemUptime) }
    }

    private func checkFocus() {
        guard let target else { return }
        do { try validateCurrent(target) }
        catch {
            if suggestionKeys.state != .idle { onSuggestionDismiss?(.focusChanged) }
            else { cancel(error) }
        }
    }

    /// The focused element, a fresh reference with the default timeout; uses the timeout already set on `application`.
    nonisolated fileprivate static func focusedField(_ application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Bundle id of the process that owns an element, for the focused-field error and doctor output.
    nonisolated private static func owner(of field: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(field, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier ?? app?.localizedName ?? "pid \(pid)"
    }

    nonisolated fileprivate static func stringAttribute(_ field: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated fileprivate static func validateEditable(_ field: AXUIElement) throws {
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

    /// Insertion's own check, with the default timeout: the app has to answer before Jot writes into it.
    private func validateCurrent(_ target: Target) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = Self.focusedField(AXUIElementCreateApplication(target.pid)),
              CFEqual(current, target.field) else { throw InputError.targetChanged }
        try Self.validateEditable(current)
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

    private func typeUnicode(_ text: String, into target: Target, generation: Int) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw ClipboardInsertion.Failure.directUnavailable }
        // Construct everything before dispatch: allocation failure must not leave partial text.
        let events = try UnicodeTyping.chunks(text).map { chunk -> (CGEvent, CGEvent) in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw ClipboardInsertion.Failure.directUnavailable }
            down.flags = []; up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
            return (down, up)
        }
        for (down, up) in events {
            try validateTransaction(target, generation: generation)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    private func paste(_ text: String, into target: Target) throws {
        clipboardRestore?()
        clipboardRestore = nil
        pasteGeneration += 1
        let generation = pasteGeneration
        let clipboard = NSPasteboard.general
        let originalChangeCount = clipboard.changeCount
        let saved = try ClipboardInsertion.snapshot(clipboard)
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
        guard clipboard.changeCount == originalChangeCount else { throw ClipboardInsertion.Failure.unavailable }
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
        guard wroteText else { restore(); throw ClipboardInsertion.Failure.unavailable }
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

/// What one re-read of the captured field found. `DictationInput` compares it with the `SuggestionField` a card was made from.
struct SuggestionFieldReadback: Sendable {
    let draft: SuggestionDraftSnapshot
    let role: String
    let placeholder: String?
    /// The field's rectangle in AppKit coordinates; nil when the app reports no usable one.
    let frame: CGRect?
    /// The raw AX value and the hint it turned out to be, if any, for `DictationInput`'s hint cache.
    let value: String
    let drawnHint: String?
}

/// Reads the captured field again on any thread. Every call goes to a fresh element reference with a short timeout, so a
/// slow app costs milliseconds per attribute rather than the six-second default, and the reference insertion uses keeps
/// its own timeout. A top-level type, so nothing about it is main-actor isolated; `@unchecked` because `AXUIElement` is a
/// thread-safe CF object the compiler cannot vouch for.
struct SuggestionFieldReader: @unchecked Sendable {
    fileprivate let pid: pid_t
    fileprivate let field: AXUIElement
    fileprivate let knownHint: (value: String, hint: String?)?
    fileprivate let primaryScreenHeight: CGFloat
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

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
