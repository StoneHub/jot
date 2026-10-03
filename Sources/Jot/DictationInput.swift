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
    private let eventTap = ShortcutEventTap()
    private var tapEpoch = 0
    private var activationObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var focusObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var target: Target?
    var shortcut: DictationShortcut = .fn { didSet { eventTap.resetGesture(); refreshShortcutState() } }
    var isRecordingShortcut = false { didSet { eventTap.resetGesture(); dismissSuggestionKeys(); refreshShortcutState() } }
    var dictationEnabled = true { didSet { refreshShortcutState() } }
    var suggestionShortcut: DictationShortcut? { didSet { refreshShortcutState() } }
    var fnSuggestionsEnabled = false { didSet { eventTap.resetFnSuggestion(); refreshShortcutState() } }
    var suggestionAllowed: () -> Bool = { false }
    var onSuggestionRequest: (() -> Void)?
    /// A request the service cannot take right now, so the gesture is not a silent no-op.
    var onSuggestionRefused: (() -> Void)?
    var onSuggestionAccept: (() -> Void)?
    var onSuggestionDismiss: ((SuggestionHistoryEntry.Action) -> Void)?
    private var suggestionKeyRevision = 0
    var suggestionState: SuggestionKeyTracker.State { eventTap.suggestionState }
    func showSuggestionKeys(_ state: SuggestionKeyTracker.State) { eventTap.showSuggestion(state); refreshShortcutState() }
    func dismissSuggestionKeys() { eventTap.dismissSuggestion(); refreshShortcutState() }

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
            "eventTapEnabled": eventTap.isTapEnabled,
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
    private var targetAcquisition: Task<AccessibilityElement, Error>?
    private static let pasteEventMarker: Int64 = 0x50534F524348

    private struct Target {
        let pid: pid_t
        let field: AXUIElement
    }

    init(onStart: @escaping () -> Void, onStop: @escaping (TimeInterval) -> Void) {
        self.onStart = onStart
        self.onStop = onStop
    }

    isolated deinit {
        // The C callbacks hold an unretained context; remove their sources before
        // this instance can disappear even if its owner forgot to call disable().
        eventTap.stop()
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        clipboardRestore?()
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard Self.accessibilityGranted else {
            report(InputError.accessibilityRequired)
            return false
        }
        refreshShortcutState()
        tapEpoch += 1
        let epoch = tapEpoch
        guard eventTap.start(onDecision: { [weak self] decision in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, self.tapEpoch == epoch else { return }
                self.apply(decision)
            }
        }) else {
            report(InputError.eventTapUnavailable)
            return false
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let front = NSWorkspace.shared.frontmostApplication {
                    let pid = front.processIdentifier
                    Task.detached { Self.wakeAccessibility(pid) }
                }
                self?.focusChanged()
            }
        }
        // A drag or window click finishes an interactive screenshot; the keys after it belong to the field again.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.eventTap.endScreenshot() }
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidatePendingTarget() }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            Task.detached { Self.wakeAccessibility(pid) }
        }
        isEnabled = true
        return true
    }

    func disable() {
        isEnabled = false
        tapEpoch += 1
        eventTap.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        onSuggestionDismiss?(.serviceStopped)
        gestureAccepted = false
        clearTarget()
        if recording { recording = false; onStop(ProcessInfo.processInfo.systemUptime) }
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
        AXUIElementSetMessagingTimeout(application, 0.005)
        let field = try editableField(in: application, of: app)
        target = Target(pid: app.processIdentifier, field: field)
        observeFocus(application, pid: app.processIdentifier)
    }

    /// Electron and Chromium apps keep their accessibility tree off until asked. The first failed look wakes it and looks once more.
    private func editableField(in application: AXUIElement, of app: NSRunningApplication) throws -> AXUIElement {
        let name = app.bundleIdentifier ?? app.localizedName ?? "unknown app"
        guard let field = Self.focusedField(application) else {
            throw InputError.noTextField(app: name, role: "no focused element")
        }
        AXUIElementSetMessagingTimeout(field, 0.005)
        try Self.validateEditable(field)
        return field
    }

    /// Electron honors AXManualAccessibility; native apps ignore it. Harmless to set every time an app comes to the front.
    nonisolated static func wakeAccessibility(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Screen rectangle of the captured field in AppKit coordinates, or nil when the app is not in front or does not report one.
    /// A busy target app must not be allowed to block the read for long.
    func targetFrame(timeout: Float = 0.005) -> CGRect? {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let primary = NSScreen.screens.first else { return nil }
        // Captured identities always retain a short timeout, including insertion.
        AXUIElementSetMessagingTimeout(target.field, timeout)
        defer { AXUIElementSetMessagingTimeout(target.field, 0.005) }
        return Self.frame(of: target.field, primaryScreenHeight: primary.frame.height)
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

    /// Ends a service-cancelled or empty utterance without calling its callbacks again.
    /// Keeps the physical shortcut state so holding the key cannot accidentally restart capture.
    func discardTarget() {
        recording = false
        clearTarget()
    }

    /// Never equates a successful AX call or dispatched shortcut with verified insertion.
    /// Field contents are used transiently for verification and never included in diagnostics.
    func insert(_ text: String, expected: SuggestionField? = nil) async throws -> DeliveryResult {
        // A quick recognition result can beat the asynchronous AX lookup. Wait only
        // for this press's bounded lookup, then keep the usual fail-closed behavior.
        if target == nil {
            for _ in 0..<14 where targetAcquisition != nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let target else { throw InputError.targetChanged }
        let generation = targetGeneration
        var path = "accessibility"
        defer { if targetGeneration == generation { clearTarget() } }
        do {
            try validateTransaction(target, generation: generation)
            guard !text.isEmpty else { return delivery(target, path: "none", outcome: "empty", verified: false) }
            if let expected, !(await suggestionFieldIsCurrent(expected)) { throw InputError.targetChanged }
            let before = await snapshot(target, forSuggestion: expected != nil)
            try validateTransaction(target, generation: generation)
            if let expected, !matches(before, expected: expected) { throw InputError.targetChanged }
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
                let after = await snapshot(target, forSuggestion: expected != nil)
                try validateTransaction(target, generation: generation)
                let readback = FieldInsertionReadback.compare(before, after, inserted: text, requireValue: expected != nil)
                if readback == .verified { return delivery(target, path: path, outcome: "verified", verified: true) }
                if !readback.allowsAccessibilityRetry(after: result) {
                    return delivery(target, path: path, outcome: "ambiguous_ax_write_no_retry", verified: false)
                }
            }
            path = "clipboard_hid"
            // Use a fresh snapshot; do not overwrite a user's edit made while AX settled.
            try validateTransaction(target, generation: generation)
            if let expected, !(await suggestionFieldIsCurrent(expected)) { throw InputError.targetChanged }
            let pasteBefore = await snapshot(target, forSuggestion: expected != nil)
            try validateTransaction(target, generation: generation)
            if let expected, !matches(pasteBefore, expected: expected) { throw InputError.targetChanged }
            if attemptedAX {
                switch FieldInsertionReadback.compare(before, pasteBefore, inserted: text, requireValue: expected != nil) {
                case .verified: return delivery(target, path: "accessibility", outcome: "verified", verified: true)
                case .changed: return delivery(target, path: "accessibility", outcome: "changed_unverified_no_retry", verified: false)
                default: break
                }
            }
            // Prefer direct text events. Clipboard fallback is safe only if no direct events were sent.
            path = try await ClipboardInsertion.deliver(paste: {
                path = "clipboard_hid"
                try paste(text, into: target)
            }, type: {
                path = "unicode_hid"
                try await typeUnicode(text, into: target, generation: generation)
            })
            for delay in [70_000_000, 130_000_000, 250_000_000, 300_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: delay)
                try validateTransaction(target, generation: generation)
                let after = await snapshot(target, forSuggestion: expected != nil)
                try validateTransaction(target, generation: generation)
                switch FieldInsertionReadback.compare(pasteBefore, after, inserted: text, requireValue: expected != nil) {
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
        let generation: Int
        let keyRevision: Int
    }

    /// The captured field as it is now, or nil when its app is not in front, focus moved, or it cannot be read safely.
    func readSuggestionField() async -> SuggestionField? {
        let generation = targetGeneration
        let revision = suggestionKeyRevision
        guard let target, let reader = suggestionFieldReader(for: target) else { return nil }
        let readback = await Task.detached(priority: .userInitiated) { reader.read() }.value
        guard !Task.isCancelled, generation == targetGeneration, revision == suggestionKeyRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let readback else { return nil }
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
        guard let target, await suggestionFieldIsCurrent(expected) else { throw InputError.targetChanged }
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
        guard await suggestionFieldIsCurrent(updated) else {
            // Only put the caret back while the text is still the user's original draft.
            if expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
               await readSuggestionField()?.draft.value == draft.value, expected.generation == targetGeneration {
                _ = select(draft.location, draft.length)
            }
            throw InputError.selectionUnavailable
        }
        return try await insert(text, expected: updated)
    }

    /// Reads the text around the captured field later, off the main thread. Only the field's frame and window are read here.
    func screenContextReader() -> ScreenContextReader? {
        guard let target else { return nil }
        AXUIElementSetMessagingTimeout(target.field, 0.005)
        defer { AXUIElementSetMessagingTimeout(target.field, 0.005) }
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
        defer { AXUIElementSetMessagingTimeout(target.field, 0.005) }
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

    func suggestionFieldIsCurrent(_ expected: SuggestionField) async -> Bool {
        guard expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              let current = await readSuggestionField() else { return false }
        return current.generation == expected.generation && current.bundleID == expected.bundleID
            && current.role == expected.role && current.draft == expected.draft && current.placeholder == expected.placeholder
    }

    /// Last hint search, by field and exact reported value, so the card's 250 ms re-reads stay cheap.
    private var drawnHint: (field: AXUIElement, value: String, hint: String?)?

    private func knownHint(for field: AXUIElement) -> (value: String, hint: String?)? {
        guard let cached = drawnHint, CFEqual(cached.field, field) else { return nil }
        return (cached.value, cached.hint)
    }

    /// Hint text that a web editor draws inside the field and reports as its value, or nil when the value is the
    /// user's. Looks only a few levels into short values; see `FieldHint`. The field keeps its caller's timeout, which
    /// insertion relies on; descendants get a short one.
    nonisolated static func drawnHint(in field: AXUIElement, value: String) -> String? {
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

    nonisolated static func selectedRange(of field: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Copies field text off the main actor. Each worker configures a fresh AX
    /// reference, and the caller revalidates focus/generation before any write.
    private func snapshot(_ target: Target, forSuggestion: Bool = false) async -> FieldInsertionSnapshot {
        if forSuggestion {
            guard let draft = await readSuggestionField()?.draft else {
                return FieldInsertionSnapshot(value: nil, selection: nil)
            }
            return FieldInsertionSnapshot(value: draft.value, selection: NSRange(location: draft.location, length: draft.length))
        }
        let pid = target.pid
        let identity = AccessibilityElement(value: target.field)
        return await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.005)
            guard let field = Self.focusedField(application), CFEqual(field, identity.value) else {
                return FieldInsertionSnapshot(value: nil, selection: nil)
            }
            AXUIElementSetMessagingTimeout(field, 0.005)
            let selection = Self.selectedRange(of: field).map { NSRange(location: $0.location, length: $0.length) }
            return FieldInsertionSnapshot(value: Self.stringAttribute(field, kAXValueAttribute), selection: selection)
        }.value
    }

    private func matches(_ snapshot: FieldInsertionSnapshot, expected: SuggestionField) -> Bool {
        snapshot.value == expected.draft.value
            && snapshot.selection?.location == expected.draft.location
            && snapshot.selection?.length == expected.draft.length
    }

    private func validateTransaction(_ target: Target, generation: Int) throws {
        try Task.checkCancellation()
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

    /// Refresh the tap thread's immutable view of settings and current availability.
    /// The action is checked again on main before requesting or accepting a suggestion.
    func refreshShortcutState() {
        let allowed = !recording && suggestionAllowed()
        eventTap.configure { config in
            config.shortcut = shortcut
            config.suggestionShortcut = suggestionShortcut
            config.dictationEnabled = dictationEnabled
            config.fnSuggestionsEnabled = fnSuggestionsEnabled
            config.suggestionAllowed = allowed
            config.recordingShortcut = isRecordingShortcut
        }
    }

    /// Decisions arrive in physical key order. Main-actor work never holds the tap.
    private func apply(_ decision: ShortcutEventTap.Decision) {
        for action in decision.actions {
            switch action {
            case .typed:
                suggestionKeyRevision += 1
                invalidatePendingTarget()
            case .suggestionRequest:
                if suggestionAllowed() { scheduleSuggestionRequest() } else { onSuggestionRefused?() }
            case .suggestionAccept:
                if eventTap.suggestionState == .accepting { onSuggestionAccept?() }
            case .suggestionDismiss(let reason):
                suggestionKeyRevision += 1
                if eventTap.suggestionState == .idle { onSuggestionDismiss?(reason) }
            case .suggestionRefused:
                onSuggestionRefused?()
            case .start:
                onSuggestionDismiss?(.typedOver)
                shortcutPresses += 1
                if shortcut.keyCode == nil { fnPresses += 1 }
                if let reason = startBlocker() {
                    gestureAccepted = false
                    busyPresses += 1
                    report(InputError.pressIgnored(shortcut: shortcut.displayName, reason: reason))
                    break
                }
                gestureAccepted = true
                recording = true
                acceptedPresses += 1
                lastShortcutError = nil
                beginShortcutTargetAcquisition()
                onStart()
            case .stop(let timestamp):
                if recording {
                    recording = false
                    onStop(timestamp)
                }
                gestureAccepted = false
            case .discardTap, .doubleTap:
                let acceptedTap = gestureAccepted
                gestureAccepted = false
                if acceptedTap {
                    recording = false
                    discardedTaps += 1
                    clearTarget()
                    onDiscardTap?()
                }
                if case .doubleTap = action, shortcut.keyCode == nil && fnSuggestionsEnabled {
                    if suggestionAllowed() { scheduleSuggestionRequest() } else { onSuggestionRefused?() }
                }
            case .cancel:
                if recording { cancel(InputError.shortcutCancelled) }
                gestureAccepted = false
            case .tapDisabled:
                onSuggestionDismiss?(.serviceStopped)
                cancel(InputError.shortcutCancelled)
                gestureAccepted = false
            }
        }
        refreshShortcutState()
    }

    private func beginShortcutTargetAcquisition() {
        clearTarget()
        let generation = targetGeneration
        guard Self.accessibilityGranted else {
            targetCaptureFailures += 1
            report(InputError.accessibilityRequired)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            targetCaptureFailures += 1
            report(InputError.noTextField(app: "no other app in front", role: "none"))
            return
        }
        let pid = app.processIdentifier
        let ticket = ShortcutTargetTicket(generation: generation, pid: pid)
        let application = AXUIElementCreateApplication(pid)
        // Registration and final identity validation run on main; the detached
        // acquisition has its own application reference with a longer budget.
        AXUIElementSetMessagingTimeout(application, 0.005)
        observeFocus(application, pid: pid)
        let acquisition = ShortcutTargetAcquisition(pid: pid,
            appName: app.bundleIdentifier ?? app.localizedName ?? "unknown app")
        let applicationReference = AccessibilityElement(value: application)
        let acquisitionTask = Task.detached(priority: .userInitiated) {
            try await acquisition.acquire()
        }
        targetAcquisition = acquisitionTask
        Task { [weak self] in
            let result = await acquisitionTask.result
            guard let self, ticket.accepts(generation: self.targetGeneration,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return }
            self.targetAcquisition = nil
            do {
                let field = try result.get().value
                guard let focused = Self.focusedField(applicationReference.value),
                      CFEqual(focused, field) else { throw InputError.targetChanged }
                AXUIElementSetMessagingTimeout(focused, 0.005)
                try Self.validateEditable(focused)
                guard ticket.accepts(generation: self.targetGeneration,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return }
                self.target = Target(pid: pid, field: field)
            } catch {
                self.targetCaptureFailures += 1
                self.report(error)
            }
        }
    }

    private func scheduleSuggestionRequest() {
        suggestionKeyRevision += 1
        let revision = suggestionKeyRevision
        let requestedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        eventTap.showSuggestion(.requesting)
        Task { @MainActor [weak self] in
            guard let self, self.eventTap.suggestionState == .requesting,
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
            if eventTap.suggestionState != .idle { onSuggestionDismiss?(.focusChanged) }
            else { cancel(error) }
        }
    }

    private func focusChanged() {
        if targetAcquisition != nil { invalidatePendingTarget() }
        else { checkFocus() }
    }

    private func invalidatePendingTarget() {
        guard targetAcquisition != nil else { return }
        clearTarget()
        targetCaptureFailures += 1
        report(InputError.targetChanged)
    }

    /// The focused element, a fresh reference with the default timeout; uses the timeout already set on `application`.
    nonisolated static func focusedField(_ application: AXUIElement) -> AXUIElement? {
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

    nonisolated static func stringAttribute(_ field: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func validateEditable(_ field: AXUIElement) throws {
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

    /// Insertion's focus check uses short timeouts; an app that does not answer is never written into.
    private func validateCurrent(_ target: Target) throws {
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.005)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = Self.focusedField(application),
              CFEqual(current, target.field) else { throw InputError.targetChanged }
        AXUIElementSetMessagingTimeout(current, 0.005)
        try Self.validateEditable(current)
    }

    private func observeFocus(_ application: AXUIElement, pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let controller = Unmanaged<DictationInput>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.focusChanged() }
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
        targetAcquisition?.cancel()
        targetAcquisition = nil
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

    private func typeUnicode(_ text: String, into target: Target, generation: Int) async throws {
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
            await Task.yield()
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

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
