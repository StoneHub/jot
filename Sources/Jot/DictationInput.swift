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
    private(set) var target: Target?
    var shortcut: DictationShortcut = .fn { didSet { eventTap.resetGesture(); refreshShortcutState() } }
    var isRecordingShortcut = false { didSet { eventTap.resetGesture(); dismissSuggestionKeys(); refreshShortcutState() } }
    var dictationEnabled = true { didSet { refreshShortcutState() } }
    var suggestionShortcut: DictationShortcut? { didSet { refreshShortcutState() } }
    /// Nil while Fix typos is off or its shortcut would take another shortcut's key.
    var typoFixShortcut: DictationShortcut? { didSet { refreshShortcutState() } }
    var onTypoFixRequest: (() -> Void)?
    /// Ends a Fix typos request in flight: the user typed, focus left its field, or a dictation hold began.
    var onTypoFixInterrupted: (() -> Void)?
    /// Fix typos holds the captured field while it runs: focus leaving it ends the fix rather than reporting a dictation error.
    var typoFixOwnsTarget = false
    /// The user typed, clicked or brought another app forward, so the field a double-Fn sequence was in may have changed.
    var onFieldActivity: (() -> Void)?
    var fnSuggestionsEnabled = false { didSet { eventTap.resetFnSuggestion(); refreshShortcutState() } }
    var suggestionAllowed: () -> Bool = { false }
    var onSuggestionRequest: (() -> Void)?
    /// A request the service cannot take right now, so the gesture is not a silent no-op.
    var onSuggestionRefused: (() -> Void)?
    var onSuggestionAccept: (() -> Void)?
    var onSuggestionDismiss: ((SuggestionHistoryEntry.Action) -> Void)?
    private(set) var suggestionKeyRevision = 0
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
    /// Why the last captured field was let go before or during delivery, as a fixed phrase; never field contents.
    private(set) var lastTargetLoss: String?
    /// What the latest focus read found, kept for `lastTargetLoss` when that read lets the field go.
    private var focusFinding = ""
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
        if let lastTargetLoss { result["lastTargetLoss"] = lastTargetLoss }
        return result
    }

    private func report(_ error: Error) {
        lastShortcutError = error.localizedDescription
        lastRejection = error.localizedDescription
        onError?(error)
    }

    private var recording = false
    /// A hold, or a released dictation still waiting to insert, owns the captured field.
    var dictationOwnsTarget: Bool { recording || target != nil || targetAcquisition != nil }
    /// Stays true through focus-error completion until the physical gesture ends.
    private var gestureAccepted = false
    var clipboardRestore: (() -> Void)?
    var pasteGeneration = 0
    private(set) var targetGeneration = 0
    private(set) var targetAcquisition: Task<AccessibilityElement, Error>?
    /// Last hint search, by field and exact reported value, so the card's 250 ms re-reads stay cheap.
    var drawnHint: (field: AXUIElement, value: String, hint: String?)?

    struct Target {
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

    /// Whether this run has already shown macOS's Accessibility prompt.
    private(set) var accessibilityPrompted = false

    func requestAccessibility() {
        accessibilityPrompted = true
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
                self?.onFieldActivity?()
            }
        }
        // A drag or window click finishes an interactive screenshot; the keys after it belong to the field again.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.eventTap.endScreenshot() }
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidatePendingTarget(); self?.onFieldActivity?() }
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
        lastTargetLoss = nil
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

    /// Ends a service-cancelled or empty utterance without calling its callbacks again.
    /// Keeps the physical shortcut state so holding the key cannot accidentally restart capture.
    func discardTarget() {
        recording = false
        clearTarget()
    }

    @discardableResult
    func delivery(_ target: Target, path: String, outcome: String, verified: Bool) -> DeliveryResult {
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
            config.typoFixShortcut = typoFixShortcut
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
                onTypoFixInterrupted?()
                onFieldActivity?()
            case .typoFixRequest:
                onTypoFixRequest?()
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
                // Before the hold captures its own field, which a running fix would otherwise let go of.
                onTypoFixInterrupted?()
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
                // A released dictation keeps its target until insertion; only an active hold is cut short.
                if recording { cancel(InputError.shortcutCancelled) }
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
        let acquisitionTask = Task.detached(priority: .userInitiated) {
            try await acquisition.acquire()
        }
        targetAcquisition = acquisitionTask
        Task { [weak self] in
            let result = await acquisitionTask.result
            guard let self, ticket.accepts(generation: self.targetGeneration,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return }
            // The acquisition stays pending until the field is confirmed, so a quick release waits for it in `insert`
            // and a click or key press meanwhile still invalidates the press.
            do {
                let candidate = Target(pid: pid, field: try result.get().value)
                try await self.confirmCurrent(candidate, generation: ticket.generation)
                guard ticket.accepts(generation: self.targetGeneration,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return }
                self.targetAcquisition = nil
                self.target = candidate
                self.lastTargetLoss = nil
            } catch {
                // A busy app may have been given a moment to answer; a newer press or release owns the field by now.
                guard self.targetGeneration == ticket.generation else { return }
                self.targetAcquisition = nil
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

    /// A focus notification from the target app. Only an answer naming another element lets the field go here: a busy
    /// app is asked again, and every write checks focus for itself before it lands.
    private func checkFocus() {
        guard let target else { return }
        let check: FocusCheck
        do { check = try focusCheck(target) } catch { targetLost(error); return }
        switch check {
        case .current: return
        case .moved: lastTargetLoss = focusFinding; targetLost(InputError.targetChanged)
        case .noAnswer:
            guard focusRecheck == nil else { return }
            let generation = targetGeneration
            focusRecheck = Task { [weak self] in
                defer { self?.focusRecheck = nil }
                guard let self, let target = self.target, self.targetGeneration == generation else { return }
                do { try await self.confirmCurrent(target, generation: generation) }
                catch { if self.targetGeneration == generation { self.targetLost(error) } }
            }
        }
    }

    /// One recheck at a time after focus notifications that got no answer; a burst of them shares it.
    private var focusRecheck: Task<Void, Never>?

    private func targetLost(_ error: Error) {
        if typoFixOwnsTarget { onTypoFixInterrupted?() }
        else if eventTap.suggestionState != .idle { onSuggestionDismiss?(.focusChanged) }
        else { cancel(error) }
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

    /// Reads that wait for a busy app before a write: 15 reads 15 ms apart, about 300 ms with each read's 5 ms timeout.
    static let focusReadAttempts = 15
    static let focusReadInterval: Duration = .milliseconds(15)

    /// Where focus is now, against the captured field. Each read has a 5 ms timeout, so a hung app never stalls Jot;
    /// a timeout is reported as `.noAnswer`, not as focus moving. Throws when the field stopped being one Jot may write into.
    func focusCheck(_ target: Target) throws -> FocusCheck {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            focusFinding = "another app came to the front"
            return .moved
        }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.005)
        let current: AXUIElement
        switch Self.focusRead(application) {
        case .noAnswer:
            focusFinding = "the app did not answer focus reads"
            return .noAnswer
        case .nothing:
            focusFinding = "nothing had focus"
            return .moved
        case .element(let element): current = element
        }
        guard CFEqual(current, target.field) else {
            focusFinding = "focus moved to another element"
            return .moved
        }
        AXUIElementSetMessagingTimeout(current, 0.005)
        // The role and subrole reads behind the editable check can time out the same way: silence, not a refusal.
        guard case .answered(let role) = Self.stringRead(current, kAXRoleAttribute),
              case .answered(let subrole) = Self.stringRead(current, kAXSubroleAttribute) else {
            focusFinding = "the app did not answer focus reads"
            return .noAnswer
        }
        try Self.validateEditable(current, role: role, subrole: subrole)
        return .current
    }

    /// Synchronous focus check for the moment just before a paste: an app that does not answer is never written into.
    func validateCurrent(_ target: Target) throws {
        guard try focusCheck(target) == .current else { lastTargetLoss = focusFinding; throw InputError.targetChanged }
    }

    /// Focus check before each write of a delivery. An app that does not answer is asked again for about 300 ms
    /// without blocking Jot, and still never written into; an answer naming another element ends it at once.
    /// The reason is recorded only while `generation` is still the current capture.
    func confirmCurrent(_ target: Target, generation: Int) async throws {
        let check = try await FocusCheck.settle(attempts: Self.focusReadAttempts,
            wait: { try await Task.sleep(for: Self.focusReadInterval) },
            read: { try self.focusCheck(target) })
        guard check == .current else {
            if targetGeneration == generation {
                lastTargetLoss = check == .noAnswer ? "the app did not answer focus reads for 300 ms" : focusFinding
            }
            throw InputError.targetChanged
        }
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

    func clearTarget() {
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
}
