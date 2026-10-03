import AppKit
import JotCore

/// The tap and its key state live together on a dedicated run loop. The lock protects
/// configuration supplied by the main actor and the small amount of state it reads.
/// No AppKit, Accessibility, or owner callback runs in the event-tap callback.
final class ShortcutEventTap: @unchecked Sendable {
    struct Configuration {
        var shortcut: DictationShortcut = .fn
        var suggestionShortcut: DictationShortcut?
        var dictationEnabled = true
        var fnSuggestionsEnabled = false
        var suggestionAllowed = false
        var recordingShortcut = false
    }

    enum Action: Equatable {
        case start, stop(TimeInterval), discardTap, doubleTap, cancel
        case suggestionRequest, suggestionAccept, suggestionDismiss(SuggestionHistoryEntry.Action)
        case suggestionRefused, typed
        case tapDisabled
    }

    struct Decision: Equatable {
        let consume: Bool
        let actions: [Action]
    }

    private let lock = NSLock()
    private var configuration = Configuration()
    private var tracker = ShortcutTracker()
    private var suggestionFn = SuggestionFnGesture()
    private var suggestionKeys = SuggestionKeyTracker()
    private var recording = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var ready: DispatchSemaphore?
    private var onDecision: ((Decision) -> Void)?
    private var running = false
    private static let pasteEventMarker: Int64 = 0x50534F524348

    var isTapEnabled: Bool { lock.withLock { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false } }
    var suggestionState: SuggestionKeyTracker.State { lock.withLock { suggestionKeys.state } }

    func configure(_ update: (inout Configuration) -> Void) {
        lock.withLock { update(&configuration) }
    }

    func resetGesture() {
        lock.withLock {
            tracker.reset()
            suggestionFn.reset()
            recording = false
        }
    }

    func resetFnSuggestion() {
        lock.withLock { suggestionFn.reset() }
    }

    func showSuggestion(_ state: SuggestionKeyTracker.State) {
        lock.withLock { suggestionKeys.show(state) }
    }

    func dismissSuggestion() {
        lock.withLock { suggestionKeys.dismiss() }
    }

    func endScreenshot() {
        lock.withLock { suggestionKeys.endScreenshot() }
    }

    /// Pure classifier seam for the recovery checks; no tap or keyboard permission.
    func decideForTesting(_ kind: ShortcutTracker.Event, keyCode: UInt16,
                          modifiers: ShortcutModifiers, repeating: Bool = false,
                          at timestamp: TimeInterval) -> Decision {
        lock.withLock { classify(kind, keyCode: keyCode, modifiers: modifiers,
                                 repeating: repeating, at: timestamp) }
    }

    /// The start handshake ensures the C callback never sees a partially installed source.
    func start(onDecision: @escaping (Decision) -> Void) -> Bool {
        let signal = DispatchSemaphore(value: 0)
        let shouldStart = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            ready = signal
            self.onDecision = onDecision
            return true
        }
        guard shouldStart else { return isTapEnabled }
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "Jot shortcut event tap"
        worker.qualityOfService = .userInteractive
        lock.withLock { thread = worker }
        worker.start()
        guard signal.wait(timeout: .now() + 2) == .success else {
            stop()
            return false
        }
        let installed = lock.withLock { tap != nil }
        if !installed { stop() }
        return installed
    }

    func stop() {
        let loop = lock.withLock { () -> CFRunLoop? in
            running = false
            onDecision = nil
            return runLoop
        }
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
        // The callback context holds an unretained reference, so wait for the thread
        // to remove its source before its owner can release this object.
        while lock.withLock({ thread?.isExecuting ?? false }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        lock.withLock {
            tracker.reset()
            suggestionFn.reset()
            suggestionKeys.reset()
            recording = false
        }
    }

    private func run() {
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let worker = Unmanaged<ShortcutEventTap>.fromOpaque(context).takeUnretainedValue()
                return worker.handle(type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        let newSource = newTap.flatMap { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) }
        let loop = CFRunLoopGetCurrent()
        lock.withLock {
            tap = newTap
            source = newSource
            runLoop = loop
            if let newSource { CFRunLoopAddSource(loop, newSource, .commonModes) }
            if let newTap { CGEvent.tapEnable(tap: newTap, enable: true) }
            ready?.signal()
            ready = nil
        }
        if newTap != nil {
            while lock.withLock({ running }) {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        lock.withLock {
            if let newTap { CGEvent.tapEnable(tap: newTap, enable: false); CFMachPortInvalidate(newTap) }
            if let newSource { CFRunLoopRemoveSource(loop, newSource, .commonModes) }
            tap = nil
            source = nil
            runLoop = nil
            thread = nil
        }
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let callback = lock.withLock { () -> ((Decision) -> Void)? in
                tracker.reset(); suggestionFn.reset(); suggestionKeys.reset(); recording = false
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return onDecision
            }
            callback?(Decision(consume: false, actions: [.tapDisabled]))
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.pasteEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let kind: ShortcutTracker.Event
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        let timestamp = event.timestamp == 0 ? ProcessInfo.processInfo.systemUptime : Double(event.timestamp) / 1_000_000_000
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ShortcutModifiers(event.flags)
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let (decision, callback) = lock.withLock { () -> (Decision, ((Decision) -> Void)?) in
            guard running else { return (Decision(consume: false, actions: []), nil) }
            return (classify(kind, keyCode: keyCode, modifiers: modifiers, repeating: repeating, at: timestamp), onDecision)
        }
        if !decision.actions.isEmpty { callback?(decision) }
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }

    /// Called only with the lock held. This is pure key classification; decisions are
    /// queued in physical event order even if main is busy handling a previous press.
    private func classify(_ kind: ShortcutTracker.Event, keyCode: UInt16, modifiers: ShortcutModifiers,
                          repeating: Bool, at timestamp: TimeInterval) -> Decision {
        let config = configuration
        guard !config.recordingShortcut else { return Decision(consume: false, actions: []) }
        if ShortcutTracker.isFnCompanionEvent(kind, keyCode: keyCode) { return Decision(consume: false, actions: []) }
        let unmodifiedFn = modifiers.subtracting(.fn)
        let allowed = !recording && config.suggestionAllowed
        let suggestion = suggestionKeys.handle(kind, keyCode: keyCode, modifiers: unmodifiedFn,
            repeating: repeating, shortcut: config.suggestionShortcut, allowed: allowed, at: timestamp)
        var actions: [Action] = []
        switch suggestion.action {
        case .request: actions.append(.suggestionRequest)
        case .accept: actions.append(.suggestionAccept)
        case .dismiss: actions.append(.suggestionDismiss(keyCode == 53 && unmodifiedFn.isEmpty ? .escape : .typedOver))
        case .none: break
        }
        if suggestion.consume { return Decision(consume: true, actions: actions) }
        if kind == .keyDown && !suggestion.screenshot { actions.append(.typed) }
        if let request = config.suggestionShortcut, request.keyCode == keyCode,
           request.modifiers == unmodifiedFn, !allowed {
            if kind == .keyDown && !repeating { actions.append(.suggestionRefused) }
            return Decision(consume: false, actions: actions)
        }
        if recording, config.shortcut.keyCode == nil, kind == .flagsChanged, modifiers.contains(.fn),
           let request = config.suggestionShortcut, !unmodifiedFn.isEmpty,
           unmodifiedFn.subtracting(request.modifiers).isEmpty {
            return Decision(consume: false, actions: actions)
        }
        if !config.dictationEnabled || config.shortcut.keyCode != nil {
            if suggestionFn.handle(kind, keyCode: keyCode, modifiers: modifiers, at: timestamp,
                                   enabled: config.fnSuggestionsEnabled) {
                actions.append(allowed ? .suggestionRequest : .suggestionRefused)
            }
        }
        guard config.dictationEnabled else { return Decision(consume: false, actions: actions) }
        let result = tracker.handle(kind, keyCode: keyCode,
            modifiers: config.shortcut.keyCode == nil ? modifiers : unmodifiedFn,
            repeating: repeating, shortcut: config.shortcut, at: timestamp)
        switch result.action {
        case .start: recording = true; actions.append(.start)
        case .stop: recording = false; actions.append(.stop(timestamp))
        case .discardTap: recording = false; actions.append(.discardTap)
        case .doubleTap: recording = false; actions.append(.doubleTap)
        case .cancel: recording = false; actions.append(.cancel)
        case .none: break
        }
        return Decision(consume: result.consume, actions: actions)
    }
}
