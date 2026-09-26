import AppKit
import Carbon
import JotCore

/// Owns automatic and explicit suggestion lifetimes. It never starts capture or speech models.
@MainActor
final class SuggestionCoordinator {
    private let input: DictationInput
    private let store: () -> TranscriptStore?
    private let allowed: () -> Bool
    private let notice: (String) -> Void
    private let card = SuggestionCard()
    private let gate = ModelCallGate()
    private var requestTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private struct AutomaticKey: Equatable {
        let probe: DictationInput.SuggestionProbe
        let sources: [SourceRevision]
    }
    private var automaticTrigger = SuggestionAutomaticTrigger<AutomaticKey>()
    private var automaticSources: [SourceRevision] = []
    private var nextSourceCheck: TimeInterval = 0
    private var automaticRequest = false
    private var monitorTask: Task<Void, Never>?
    private var sourceObserver: NSObjectProtocol?
    private var generation = 0
    private var ownsTarget = false
    private var field: DictationInput.SuggestionField?
    private var rows: [Transcript] = []
    private var candidate: String?
    private(set) var keyboardAllowsSuggestions = false
    private var requests = 0
    private var insertions = 0
    private var outcome = "idle"
    var diagnostics: [String: Any] { ["requests": requests, "insertions": insertions, "outcome": outcome, "visible": card.isVisible,
                                    "automatic": automaticTask != nil, "keyboardEligible": keyboardAllowsSuggestions] }

    init(input: DictationInput, store: @escaping () -> TranscriptStore?, allowed: @escaping () -> Bool,
         notice: @escaping (String) -> Void) {
        self.input = input; self.store = store; self.allowed = allowed; self.notice = notice
        refreshKeyboard()
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard(); self?.dismiss() } }
    }
    deinit {
        requestTask?.cancel(); monitorTask?.cancel(); automaticTask?.cancel()
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

    func setAutomaticEnabled(_ enabled: Bool) {
        guard enabled else {
            automaticTask?.cancel(); automaticTask = nil
            dismiss(); return
        }
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard self.allowed(), self.keyboardAllowsSuggestions, self.input.isEnabled,
                      !self.input.isRecordingShortcut else {
                    _ = self.automaticTrigger.observe(nil, at: ProcessInfo.processInfo.systemUptime)
                    continue
                }
                guard self.field == nil, !self.gate.outstanding else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                guard let probe = self.input.probeSuggestionField() else {
                    _ = self.automaticTrigger.observe(nil, at: now); continue
                }
                // Refresh revisions off the main thread so new speech can offer a suggestion
                // even when the draft stays blank. Empty context never starts inference.
                if now >= self.nextSourceCheck {
                    self.nextSourceCheck = now + 1
                    guard let store = self.store() else { continue }
                    let revisions = await Task.detached(priority: .utility) {
                        (try? store.suggestionContext().sources.map { SourceRevision(id: $0.id, revision: $0.revision) }) ?? []
                    }.value
                    guard !Task.isCancelled, self.allowed(), self.field == nil,
                          self.input.probeSuggestionField() == probe else { continue }
                    self.automaticSources = revisions
                }
                let key = self.automaticSources.isEmpty ? nil : AutomaticKey(probe: probe, sources: self.automaticSources)
                if self.automaticTrigger.observe(key, at: now) {
                    self.request(automatic: true, expectedProbe: probe)
                }
            }
        }
    }

    func dismiss() {
        generation += 1
        requestTask?.cancel(); requestTask = nil
        monitorTask?.cancel(); monitorTask = nil
        gate.cancel()
        card.hide(); input.dismissSuggestionKeys()
        candidate = nil; field = nil; rows = []
        if ownsTarget { ownsTarget = false; input.discardTarget() }
    }

    func request(automatic: Bool = false, expectedProbe: DictationInput.SuggestionProbe? = nil) {
        dismiss()
        automaticRequest = automatic
        guard allowed(), keyboardAllowsSuggestions else { return }
        requests += 1; outcome = "loading"
        do { try input.captureTarget(wakeRetry: false) }
        catch { outcome = "unsupported-field"; if !automatic { notice("No suggestion: focus an ordinary editable text field.") }; return }
        ownsTarget = true
        guard let field = input.readSuggestionField(), let frame = input.targetFrame(timeout: 0.005) else {
            dismiss(); if !automatic { notice("No suggestion: this field cannot be read safely.") }; return
        }
        if let expectedProbe, !input.capturedSuggestionMatches(expectedProbe, field: field) { dismiss(); return }
        self.field = field
        guard let mode = field.draft.mode(bundleID: field.bundleID, role: field.role) else {
            showNotice("No suggestion for this blank field."); return
        }
        guard let store = store() else { showNotice("No suggestion: local history is unavailable."); return }
        input.showSuggestionKeys(automatic ? .requesting : .loading)
        if !automatic { card.show(text: "Using recent Jot context…", loading: true, at: frame) }
        let token = generation
        monitor(field: field, token: token)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await Task.detached(priority: .userInitiated) { try store.suggestionContext() }.value
                guard self.isCurrent(token, field: field) else { return }
                let target = JotCore.Target(app: field.bundleID, mode: mode, purpose: mode == .reply ? "agent-prompt" : "text-entry",
                                           inputRevision: field.draft.revision, before: field.draft.before, after: field.draft.after,
                                           requestedAt: ISO8601DateFormatter().string(from: Date()))
                let scenario = context.input(target: target, association: automatic ? .automaticRecentContext : .explicitRecentRequest)
                let selection = SourceSelector.select(scenario)
                self.rows = context.rows.filter { row in selection.selected.contains { $0.id == row.id } }
                guard !selection.selected.isEmpty else { self.showNotice("No suggestion: no recent context fits."); return }
                let request = SuggestionPrompt.request(for: scenario, sources: selection.selected)
                let result = await self.gate.call(request, generator: { try await AppleFMGeneration.generate($0) })
                guard self.isCurrent(token, field: field) else { return }
                let expectedRows = self.rows
                let current = try await Task.detached { try store.suggestionRowsUnchanged(expectedRows) }.value
                guard self.isCurrent(token, field: field) else { return }
                guard current else { self.dismiss(); if !automatic { self.notice("Suggestion dismissed because its sources changed.") }; return }
                switch result {
                case .output(let raw):
                    switch SuggestionOutput.process(raw, mode: mode) {
                    case .suggestion(let text):
                        self.candidate = text; self.outcome = "ready"
                        self.input.showSuggestionKeys(.ready)
                        if let frame = self.input.targetFrame(timeout: 0.005) {
                            self.card.show(text: text, sources: context.attribution(selected: selection.selected), ready: true, at: frame)
                        } else { self.dismiss() }
                    case .abstained, .rejected: self.showNotice("No suggestion from this context.")
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
        if automaticRequest { dismiss(); return }
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
        guard let field, let text = candidate, input.suggestionState == .accepting, let store = store() else { dismiss(); return }
        let token = generation, expectedRows = rows
        monitorTask?.cancel(); card.hide()
        requestTask = Task { [weak self] in
            guard let self else { return }
            let current = await Task.detached { (try? store.suggestionRowsUnchanged(expectedRows)) == true }.value
            guard self.isCurrent(token, field: field), current else {
                if token == self.generation { self.dismiss() }
                self.notice("Nothing inserted: the field or its sources changed."); return
            }
            do {
                let result = try await self.input.insert(text, expected: field)
                if result.verified {
                    self.insertions += 1; self.outcome = "inserted"
                    if let probe = self.input.probeSuggestionField() {
                        self.automaticTrigger.suppress(AutomaticKey(probe: probe, sources: self.automaticSources), at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                else { self.outcome = "insertion-unverified"; self.notice("Insertion could not be verified. Check the field before retrying.") }
            } catch { self.outcome = "insertion-cancelled"; self.notice("Nothing inserted: the target changed.") }
            if token == self.generation { self.dismiss() }
        }
    }
}
