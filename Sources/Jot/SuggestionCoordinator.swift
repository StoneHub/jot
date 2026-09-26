import AppKit
import ApplicationServices
import Carbon
import JotCore

/// Owns explicitly requested suggestion lifetimes. It never starts capture or speech models.
@MainActor
final class SuggestionCoordinator {
    private let input: DictationInput
    private let store: () -> TranscriptStore?
    private let allowed: () -> Bool
    private let readsScreen: () -> Bool
    private let notice: (String) -> Void
    private let card = SuggestionCard()
    private let gate = ModelCallGate()
    private var requestTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var sourceObserver: NSObjectProtocol?
    private var generation = 0
    private var ownsTarget = false
    private var field: DictationInput.SuggestionField?
    private var rows: [Transcript] = []
    private var candidate: String?
    /// A draft replaces exactly these notes on Tab; a reply inserts at the cursor.
    private var seed: SuggestionSeed?
    private(set) var keyboardAllowsSuggestions = false
    private var requests = 0
    private var insertions = 0
    private var outcome = "idle"
    private var lastMode = "none"
    private var usedScreen = false
    /// Counts and outcomes only; never field, screen, prompt or output text.
    var diagnostics: [String: Any] { ["requests": requests, "insertions": insertions, "outcome": outcome, "visible": card.isVisible,
                                    "automatic": false, "keyboardEligible": keyboardAllowsSuggestions,
                                    "mode": lastMode, "screenContext": usedScreen] }

    static let needsNotes = "Jot needs a few rough notes. Type or dictate them here, then double-tap Fn."

    init(input: DictationInput, store: @escaping () -> TranscriptStore?, allowed: @escaping () -> Bool,
         readsScreen: @escaping () -> Bool = { true }, notice: @escaping (String) -> Void) {
        self.input = input; self.store = store; self.allowed = allowed; self.readsScreen = readsScreen; self.notice = notice
        refreshKeyboard()
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard(); self?.dismiss() } }
    }
    deinit {
        requestTask?.cancel(); monitorTask?.cancel()
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
    }
    private func refreshKeyboard() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            keyboardAllowsSuggestions = false; return
        }
        keyboardAllowsSuggestions = (Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String)
            == (kTISTypeKeyboardLayout as String)
    }

    func dismiss() {
        generation += 1
        requestTask?.cancel(); requestTask = nil
        monitorTask?.cancel(); monitorTask = nil
        gate.cancel()
        card.hide(); input.dismissSuggestionKeys()
        candidate = nil; seed = nil; field = nil; rows = []
        if ownsTarget { ownsTarget = false; input.discardTarget() }
    }

    /// Notes in the field become a draft that replaces them. A blank composer gets a reply only from context associated
    /// with it: the conversation visible above it, or dictation meant for a blank Codex composer. Otherwise Jot asks for notes.
    func request() {
        dismiss()
        guard allowed(), keyboardAllowsSuggestions else { return }
        requests += 1; outcome = "loading"; lastMode = "none"; usedScreen = false
        do { try input.captureTarget(wakeRetry: false) }
        catch { outcome = "unsupported-field"; notice("No suggestion: focus an ordinary editable text field."); return }
        ownsTarget = true
        guard let field = input.readSuggestionField(), let frame = input.targetFrame(timeout: 0.005) else {
            dismiss(); notice("No suggestion: this field cannot be read safely."); return
        }
        self.field = field
        let blank = field.draft.isBlank
        if blank && field.role != kAXTextAreaRole { showNotice(Self.needsNotes); return }
        // Ambient speech is never imported by recency; recent dictation only backs a blank Codex composer.
        let store = blank && field.bundleID == "com.openai.codex" ? self.store() : nil
        let reader = readsScreen() ? input.screenContextReader() : nil
        if blank && store == nil && reader == nil { showNotice(Self.needsNotes); return }
        input.showSuggestionKeys(.loading)
        card.show(text: blank ? "Reading the conversation…" : "Drafting from your notes…", loading: true, at: frame)
        let token = generation
        monitor(field: field, token: token)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let screenTask = Task.detached(priority: .userInitiated) { reader?.read() }
                let context = try await Task.detached(priority: .userInitiated) { try store?.suggestionContext() }.value
                let screen = await screenTask.value
                guard self.isCurrent(token, field: field) else { return }
                let now = Date()
                var sources: [Source] = []
                var excerpt: String?
                if let screen, let text = ScreenContext.excerpt(screen.items, field: screen.field, visible: screen.visible) {
                    excerpt = text
                    sources.append(ScreenContext.source(text, at: now))
                }
                let dictation = context?.sources.filter { $0.kind == "dictation" } ?? []
                let plan = SuggestionPlan.make(draft: field.draft, role: field.role,
                                               hasAssociatedContext: !sources.isEmpty || !dictation.isEmpty)
                let mode: SuggestionMode
                var before = field.draft.before, after = field.draft.after
                switch plan {
                case .needsNotes:
                    self.showNotice(Self.needsNotes); return
                case .reply:
                    mode = .reply; sources += dictation
                case .draft(let seed):
                    mode = .draft; self.seed = seed
                    (before, after) = field.draft.text(around: seed)
                }
                self.lastMode = mode.rawValue
                let target = JotCore.Target(app: field.appName, mode: mode, purpose: Self.purpose(of: field),
                                            inputRevision: field.draft.revision, before: before, after: after,
                                            requestedAt: ISO8601DateFormatter().string(from: now),
                                            seed: self.seed?.text, window: screen?.window)
                var scenario = ScenarioInput(target: target, sources: sources)
                scenario.association = .explicitRecentRequest
                let selection = SourceSelector.select(scenario)
                self.usedScreen = selection.selected.contains { $0.kind == ScreenContext.kind }
                self.rows = context?.rows.filter { row in selection.selected.contains { $0.id == row.id } } ?? []
                if mode == .reply && selection.selected.isEmpty { self.showNotice(Self.needsNotes); return }
                let request = SuggestionPrompt.request(for: scenario, sources: selection.selected)
                let result = await self.gate.call(request, deadline: Self.deadline(for: mode),
                                                  generator: { try await AppleFMGeneration.generate($0) })
                guard self.isCurrent(token, field: field) else { return }
                let expectedRows = self.rows
                if !expectedRows.isEmpty, let store {
                    let current = try await Task.detached { try store.suggestionRowsUnchanged(expectedRows) }.value
                    guard self.isCurrent(token, field: field) else { return }
                    guard current else { self.dismiss(); self.notice("Suggestion dismissed because its sources changed."); return }
                }
                switch result {
                case .output(let raw):
                    switch SuggestionOutput.process(raw, mode: mode, singleLine: field.role != kAXTextAreaRole) {
                    case .suggestion(let text):
                        switch SuggestionOutput.review(text, draft: field.draft, seed: self.seed?.text,
                                                       placeholder: field.placeholder, context: excerpt) {
                        case .accept: break
                        case .unchanged: self.showNotice("Your notes already read well. No changes suggested."); return
                        case .restatesHint:
                            self.showNotice(field.draft.isBlank ? Self.needsNotes : "No suggestion: the result only repeated the field's hint.")
                            return
                        case .copiesContext: self.showNotice("No suggestion: the result only repeated text on screen."); return
                        }
                        self.candidate = text; self.outcome = "ready"
                        self.input.showSuggestionKeys(.ready)
                        guard let frame = self.input.targetFrame(timeout: 0.005) else { self.dismiss(); return }
                        let title: String, action: String
                        if let seed = self.seed {
                            title = seed.isSelection ? "Rewrite of your selection" : "Draft from your notes"
                            action = seed.isSelection ? "Tab to replace the selection" : "Tab to replace your notes"
                        } else { title = "Suggested reply"; action = "Tab to insert" }
                        self.card.show(text: text, title: title,
                                       sources: SuggestionAttribution.line(plan: plan, selected: selection.selected,
                                                                           sessionTitle: context?.sessionTitle),
                                       action: action, ready: true, at: frame)
                    case .abstained, .rejected:
                        self.showNotice(mode == .draft ? "No suggestion from these notes." : "No suggestion from this context.")
                    }
                case .unavailable: self.showNotice("No suggestion: Apple Intelligence is unavailable.")
                case .timedOut: self.showNotice("No suggestion: the model took too long.")
                case .blocked: self.showNotice("No suggestion: the previous request is still ending.")
                case .failed: self.showNotice("No suggestion: the model could not complete the request.")
                case .cancelled: self.dismiss()
                }
            } catch {
                guard token == self.generation else { return }
                self.showNotice("No suggestion: local context could not be read.")
            }
        }
    }

    /// A draft can run to several sentences; the on-device model needs longer for it than for a one-line reply.
    private static func deadline(for mode: SuggestionMode) -> Duration { mode == .draft ? .seconds(8) : .seconds(3) }

    private static func purpose(of field: DictationInput.SuggestionField) -> String {
        guard field.role == kAXTextAreaRole else { return "single-line" }
        return field.bundleID == "com.openai.codex" ? "agent-prompt" : "text-entry"
    }

    private func isCurrent(_ token: Int, field: DictationInput.SuggestionField) -> Bool {
        guard token == generation, !Task.isCancelled else { return false }
        guard allowed(), keyboardAllowsSuggestions, input.suggestionFieldIsCurrent(field) else { dismiss(); return false }
        return true
    }

    private func monitor(field: DictationInput.SuggestionField, token: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            let expires = ContinuousClock.now.advanced(by: .seconds(30))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isCurrent(token, field: field) else { return }
                guard ContinuousClock.now < expires, let frame = self.input.targetFrame(timeout: 0.005) else { self.dismiss(); return }
                self.card.place(at: frame)
                let expectedRows = self.rows
                if !expectedRows.isEmpty, let store = self.store() {
                    let current = await Task.detached { (try? store.suggestionRowsUnchanged(expectedRows)) == true }.value
                    guard token == self.generation else { return }
                    if !current { self.dismiss(); return }
                }
            }
        }
    }

    private func showNotice(_ text: String) {
        outcome = "no-suggestion"; candidate = nil
        input.showSuggestionKeys(.notice)
        guard let frame = input.targetFrame(timeout: 0.005) else { dismiss(); notice(text); return }
        card.show(text: text, at: frame)
        let token = generation
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.dismiss()
        }
    }

    func accept() {
        guard let field, let text = candidate, input.suggestionState == .accepting else { dismiss(); return }
        let token = generation, expectedRows = rows, seed = self.seed
        let store = expectedRows.isEmpty ? nil : self.store()
        guard expectedRows.isEmpty || store != nil else { dismiss(); return }
        monitorTask?.cancel(); card.hide()
        requestTask = Task { [weak self] in
            guard let self else { return }
            let current = await Task.detached { () -> Bool in
                guard !expectedRows.isEmpty else { return true }
                return (try? store?.suggestionRowsUnchanged(expectedRows)) == true
            }.value
            guard self.isCurrent(token, field: field), current else {
                if token == self.generation { self.dismiss() }
                self.notice("Nothing inserted: the field or its sources changed."); return
            }
            do {
                let result: DictationInput.DeliveryResult
                if let seed { result = try await self.input.replace(seed, with: text, expected: field) }
                else { result = try await self.input.insert(text, expected: field) }
                if result.verified { self.insertions += 1; self.outcome = "inserted" }
                else { self.outcome = "insertion-unverified"; self.notice("Insertion could not be verified. Check the field before retrying.") }
            } catch DictationInput.InputError.selectionUnavailable {
                self.outcome = "selection-unavailable"
                self.notice(DictationInput.InputError.selectionUnavailable.localizedDescription)
            } catch { self.outcome = "insertion-cancelled"; self.notice("Nothing inserted: the target changed.") }
            if token == self.generation { self.dismiss() }
        }
    }
}

/// Reads the visible text above a field in its window, for `ScreenContext`. Runs off the main thread: every call has
/// a short timeout, and the walk stops at an element and time budget. Children are visited last first, so the budget
/// goes to the newest content, nearest a chat composer. Other inputs and password fields are never read.
struct ScreenContextReader: @unchecked Sendable {
    struct Snapshot: Sendable {
        let items: [ScreenText]
        let field: CGRect
        let visible: CGRect
        let window: String?
    }

    let field: AXUIElement
    let fieldFrame: CGRect
    let parent: AXUIElement
    let window: AXUIElement?

    private static let elementLimit = 3000
    private static let budgetNanoseconds: UInt64 = 400_000_000
    private static let timeout: Float = 0.05

    func read() -> Snapshot? {
        let started = DispatchTime.now().uptimeNanoseconds
        // A browser's or Electron app's page is its web area; a native window is the fallback scope.
        var webArea: AXUIElement?
        var outermost: AXUIElement = parent
        var next: AXUIElement? = parent
        for _ in 0..<40 {
            guard let current = next else { break }
            AXUIElementSetMessagingTimeout(current, Self.timeout)
            let role = Self.string(current, kAXRoleAttribute)
            if role == "AXWebArea" { webArea = current; break }
            if role == kAXWindowRole { break }
            outermost = current
            next = Self.element(current, kAXParentAttribute)
        }
        let scope = webArea ?? window ?? outermost
        var visible = window.flatMap { Self.frame(of: $0) } ?? .infinite
        if let webArea, let area = Self.frame(of: webArea) { visible = visible.intersection(area) }
        guard !visible.isNull else { return nil }
        let column = fieldFrame.insetBy(dx: -fieldFrame.width * 0.15, dy: 0)
        let attributes = [kAXRoleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var items: [ScreenText] = []
        var bytes = 0, visited = 0
        var stack: [(element: AXUIElement, depth: Int)] = [(scope, 0)]
        while visited < Self.elementLimit, bytes < ScreenContext.maximumBytes * 3,
              DispatchTime.now().uptimeNanoseconds - started < Self.budgetNanoseconds, let entry = stack.popLast() {
            visited += 1
            if CFEqual(entry.element, field) { continue }
            AXUIElementSetMessagingTimeout(entry.element, Self.timeout)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(entry.element, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 5 else { continue }
            let role = values[0] as? String
            let frame = Self.frame(position: values[2], size: values[3])
            // Skip what is at or below the field's top, scrolled out of view, or beside the field's column.
            if let frame, frame.width > 0, frame.height > 0,
               frame.minY >= fieldFrame.minY || !frame.intersects(visible) || frame.maxX < column.minX || frame.minX > column.maxX {
                continue
            }
            if role == kAXStaticTextRole {
                if let text = values[1] as? String, let frame, !text.isEmpty {
                    items.append(ScreenText(text, frame: frame)); bytes += text.utf8.count
                }
                continue
            }
            if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { continue }
            guard entry.depth < 80, let children = values[4] as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                stack.append((element: child as! AXUIElement, depth: entry.depth + 1))
            }
        }
        return Snapshot(items: items, field: fieldFrame, visible: visible, window: window.flatMap { Self.string($0, kAXTitleAttribute) })
    }

    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let items = value as? [AnyObject] else { return [] }
        return items.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// The static text inside a small element, such as a drawn field hint. Uses the caller's timeout on `element`.
    static func staticText(under element: AXUIElement) -> String {
        var parts: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 16 {
            let entry = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(entry.element, 0.005)
            if string(entry.element, kAXRoleAttribute) == kAXStaticTextRole, let text = string(entry.element, kAXValueAttribute) {
                parts.append(text); continue
            }
            if entry.depth < 3 { queue += children(of: entry.element).map { (element: $0, depth: entry.depth + 1) } }
        }
        return parts.joined(separator: " ")
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        return frame(position: position, size: size)
    }

    /// Uses the timeout already set on `element`.
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
