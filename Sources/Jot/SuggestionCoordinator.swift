import AppKit
import ApplicationServices
import Carbon
import JotCore

/// Owns explicitly requested suggestion lifetimes. It never starts capture or speech models.
@MainActor
final class SuggestionCoordinator {
    private let input: DictationInput
    private let store: () -> TranscriptStore?
    private let history: () -> SuggestionHistory?
    private let agentContext: AgentContext
    private let allowed: () -> Bool
    private let readsScreen: () -> Bool
    /// Add one image of the window around the field, when Screen Recording is allowed and the model takes images.
    private let includesWindowImage: () -> Bool
    private let matchesHeardSpeech: () -> Bool
    /// The learned user voice, so speech in the user's voice takes the user role even with no hold in that session.
    private let userVoice: () -> UserVoice?
    /// Seconds of speech and agent messages a request may use.
    private let window: () -> TimeInterval
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
    private var agentSnapshot: [SuggestionSource] = []
    private var agentLatestID: String?
    private var candidate: String?
    private struct Receipt {
        let id = UUID()
        let startedAt = Date()
        var revision = 0
        var appBundleID: String?
        var fieldRole: SuggestionHistoryEntry.FieldRole = .unknown
        var purpose: SuggestionHistoryEntry.Purpose = .textEntry
        var plan: SuggestionHistoryEntry.Plan = .needsNotes
        var mode: SuggestionHistoryEntry.Mode = .none
        var beforeEndsSentence = true
        var draftCharacters = 0
        var selectionCharacters = 0
        var selected: [SuggestionHistoryEntry.SourceUsage] = []
        var excluded: [SuggestionHistoryEntry.ExcludedUsage] = []
        var agentInput: AgentContext.MatchState = .noMessages
        var deadlineMilliseconds: Int?
        var generationMilliseconds: Int?
        var previewMilliseconds: Int?
        var windowImage: SuggestionHistoryEntry.WindowImageOutcome?
        var windowImageMilliseconds: Int?
        var generationStartedAt: Date?
        var outcome: SuggestionHistoryEntry.Outcome = .requested
        var reason: SuggestionHistoryEntry.Reason?
        var action: SuggestionHistoryEntry.Action?
        var complete = false

        func entry() -> SuggestionHistoryEntry {
            SuggestionHistoryEntry(id: id, revision: revision, startedAt: startedAt,
                appBundleID: appBundleID, fieldRole: fieldRole, purpose: purpose, plan: plan, mode: mode,
                beforeEndsSentence: beforeEndsSentence, draftCharacters: draftCharacters,
                selectionCharacters: selectionCharacters, selected: selected, excluded: excluded,
                agentInput: agentInput, deadlineMilliseconds: deadlineMilliseconds,
                generationMilliseconds: generationMilliseconds, previewMilliseconds: previewMilliseconds,
                windowImage: windowImage, windowImageMilliseconds: windowImageMilliseconds,
                outcome: outcome, reason: reason, action: action, complete: complete)
        }
    }
    private var receipt: Receipt?
    /// A draft replaces exactly these notes on Tab; a reply inserts at the cursor.
    private var seed: SuggestionSeed?
    private(set) var keyboardAllowsSuggestions = false
    private var requests = 0
    private var insertions = 0
    private var outcome = "idle"
    /// Why the last request showed no suggestion, as a code: never field, screen, prompt or output text.
    private var reason = "none"
    private var lastMode = "none"
    private var usedScreen = false
    private var usedHeard = false
    private var usedSpeech = false
    private var usedAgent = false
    /// "off", "attached", or why no image went with the last request. Never the image.
    private var windowImage = "off"
    /// Counts and outcomes only; never field, screen, prompt or output text.
    var diagnostics: [String: Any] { ["requests": requests, "insertions": insertions, "outcome": outcome, "reason": reason, "visible": card.isVisible,
                                    "keyboardEligible": keyboardAllowsSuggestions,
                                    "mode": lastMode, "screenContext": usedScreen, "speechContext": usedSpeech,
                                    "heardContext": usedHeard, "agentContext": usedAgent, "agentMessagesHeld": agentContext.count,
                                    "windowImage": windowImage] }

    static let needsNotes = "Jot needs a few rough notes. Type or dictate them here, then double-tap Fn."

    init(input: DictationInput, store: @escaping () -> TranscriptStore?,
         history: @escaping () -> SuggestionHistory? = { nil }, agentContext: AgentContext = AgentContext(),
         allowed: @escaping () -> Bool, readsScreen: @escaping () -> Bool = { true },
         includesWindowImage: @escaping () -> Bool = { false },
         window: @escaping () -> TimeInterval = { 600 }, matchesHeardSpeech: @escaping () -> Bool = { true },
         userVoice: @escaping () -> UserVoice? = { nil }, notice: @escaping (String) -> Void) {
        self.input = input; self.store = store; self.history = history; self.agentContext = agentContext; self.allowed = allowed
        self.readsScreen = readsScreen; self.includesWindowImage = includesWindowImage
        self.window = window; self.matchesHeardSpeech = matchesHeardSpeech; self.notice = notice
        self.userVoice = userVoice
        refreshKeyboard()
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard(); self?.input.refreshShortcutState(); self?.dismiss(action: .keyboardSourceChanged) } }
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

    private func persistReceipt() {
        guard let receipt, let history = history() else { return }
        let entry = receipt.entry()
        Task { try? await history.save(entry) }
    }

    private func beginReceipt() {
        receipt = Receipt()
        persistReceipt()
    }

    private func updateReceipt(_ update: (inout Receipt) -> Void) {
        guard var current = receipt else { return }
        update(&current)
        current.revision += 1
        receipt = current
        persistReceipt()
    }

    func dismiss(action: SuggestionHistoryEntry.Action = .focusChanged) {
        updateReceipt { $0.action = action; $0.complete = true }
        receipt = nil
        generation += 1
        requestTask?.cancel(); requestTask = nil
        monitorTask?.cancel(); monitorTask = nil
        gate.cancel()
        card.hide(); input.dismissSuggestionKeys()
        candidate = nil; seed = nil; field = nil; rows = []; agentSnapshot = []; agentLatestID = nil
        if ownsTarget { ownsTarget = false; input.discardTarget() }
    }

    /// A selection becomes a rewrite that replaces it; other text is continued at the cursor; a blank composer gets a
    /// reply. All draw on the same window: the conversation visible above the field, what Jot heard, and what agents
    /// told it. A blank field with nothing in the window asks for notes.
    func request() {
        dismiss(action: .newRequest)
        beginReceipt()
        guard allowed(), keyboardAllowsSuggestions else {
            updateReceipt { $0.outcome = .blocked; $0.reason = .refused }
            dismiss(action: .serviceStopped)
            return
        }
        requests += 1; outcome = "loading"; reason = "none"; lastMode = "none"; usedScreen = false; usedSpeech = false; usedAgent = false; usedHeard = false
        windowImage = "off"
        updateReceipt { $0.outcome = .loading }
        do { try input.captureTarget(wakeRetry: false) }
        catch {
            outcome = "unsupported-field"; reason = "unsupported-field"
            updateReceipt { $0.outcome = .noSuggestion; $0.reason = .unsupportedField }
            dismiss(action: .focusChanged)
            notice("No suggestion: focus an ordinary editable text field."); return
        }
        ownsTarget = true
        guard let field = input.readSuggestionField(), let frame = input.targetFrame(timeout: 0.005) else {
            updateReceipt { $0.outcome = .noSuggestion; $0.reason = .unreadableField }
            dismiss(); reason = "unreadable-field"; notice("No suggestion: this field cannot be read safely."); return
        }
        self.field = field
        updateReceipt { receipt in
            receipt.appBundleID = SuggestionHistoryEntry.sanitizedBundleID(field.bundleID)
            switch field.role {
            case kAXTextAreaRole: receipt.fieldRole = .textArea
            case kAXTextFieldRole: receipt.fieldRole = .textField
            case kAXComboBoxRole: receipt.fieldRole = .comboBox
            default: receipt.fieldRole = .unknown
            }
            receipt.purpose = field.role != kAXTextAreaRole ? .singleLine
                : field.bundleID == "com.openai.codex" ? .agentPrompt : .textEntry
            receipt.draftCharacters = (field.draft.value as NSString).length
            receipt.selectionCharacters = field.draft.length
            receipt.beforeEndsSentence = SuggestionPrompt.endsSentence(field.draft.before)
        }
        let blank = field.draft.isBlank
        if blank && field.role != kAXTextAreaRole { showNotice(Self.needsNotes, reason: "needs-notes"); return }
        let store = self.store()
        let reader = readsScreen() ? input.screenContextReader() : nil
        let imageCapture = includesWindowImage() ? windowImageCapture() : nil
        let heardNotes = matchesHeardSpeech() ? Self.draftNotes(in: field) : nil
        let window = self.window()
        let voice = userVoice()
        let loading: String
        switch SuggestionPlan.make(draft: field.draft, role: field.role, hasAssociatedContext: true) {
        case .draft: loading = "Rewriting your selection…"
        case .continuation: loading = "Writing what comes next…"
        case .reply, .needsNotes: loading = "Reading the conversation…"
        }
        input.showSuggestionKeys(.loading)
        card.show(text: loading, loading: true, at: frame)
        let token = generation
        monitor(field: field, token: token)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let now = Date()
                let screenTask = Task.detached(priority: .userInitiated) { reader?.read() }
                let imageTask = imageCapture.map { capture in Task { await capture.capture(within: Self.windowImageBudget) } }
                defer { imageTask?.cancel() }
                let heardTask = Task.detached(priority: .userInitiated) { Self.heardSpeech(matching: heardNotes, in: store, now: now, window: window) }
                let context = try await Task.detached(priority: .userInitiated) { try store?.suggestionContext(window: window, now: now, userVoice: voice) }.value
                let screen = await screenTask.value
                let heard = await heardTask.value
                let captured = await withTaskCancellationHandler {
                    await imageTask?.value
                } onCancel: {
                    imageTask?.cancel()
                }
                guard self.isCurrent(token, field: field) else { return }
                // Taken for this field and this request only; a later request or a focus change never sees it.
                let image = captured?.image
                if let captured {
                    let outcome: SuggestionHistoryEntry.WindowImageOutcome = captured.timedOut ? .captureTimedOut
                        : image == nil ? .captureFailed : .attached
                    self.windowImage = outcome.rawValue
                    self.updateReceipt { $0.windowImage = outcome; $0.windowImageMilliseconds = captured.milliseconds }
                }
                var sources: [SuggestionSource] = []
                var excerpt: String?
                if let screen, let text = ScreenContext.excerpt(screen.items, field: screen.field, visible: screen.visible) {
                    excerpt = text
                    sources.append(ScreenContext.source(text, at: now))
                }
                sources += context?.sources ?? []
                let agentMatch = self.agentContext.match(within: window, now: now,
                    targetBundleID: field.bundleID, visibleText: excerpt)
                let agentSources = agentMatch.sources
                self.updateReceipt { $0.agentInput = agentMatch.state }
                sources += agentSources
                guard agentSources.isEmpty || self.agentContext.matchesSnapshot(agentSources, latestID: agentSources.last!.id,
                    within: window, now: now) else {
                    self.dismiss(action: .sourcesChanged); return
                }
                let plan = SuggestionPlan.make(draft: field.draft, role: field.role, hasAssociatedContext: !sources.isEmpty || image != nil)
                let mode: SuggestionMode
                var before = field.draft.before, after = field.draft.after
                switch plan {
                case .needsNotes:
                    self.updateReceipt { $0.plan = .needsNotes }
                    self.showNotice(Self.needsNotes, reason: "needs-notes"); return
                case .reply:
                    mode = .reply
                case .continuation:
                    mode = .continuation
                case .draft(let seed):
                    mode = .draft; self.seed = seed
                    (before, after) = field.draft.text(around: seed)
                }
                self.updateReceipt { receipt in
                    switch plan {
                    case .reply: receipt.plan = .reply
                    case .continuation: receipt.plan = .continuation
                    case .draft: receipt.plan = .draft
                    case .needsNotes: receipt.plan = .needsNotes
                    }
                    switch mode {
                    case .reply: receipt.mode = .reply
                    case .continuation: receipt.mode = .continuation
                    case .draft: receipt.mode = .draft
                    case .shellCommand: receipt.mode = .none
                    }
                    receipt.beforeEndsSentence = SuggestionPrompt.endsSentence(before)
                }
                self.lastMode = mode.rawValue
                // The matched agent conversation is the field's own: naming it on the target puts its turns in the selector's
                // conversation tier, above the room's speech, so a busy room cannot crowd them out of the bound.
                let target = SuggestionTarget(app: field.appName, mode: mode, purpose: Self.purpose(of: field),
                                            conversation: agentSources.first?.scope.conversation,
                                            inputRevision: field.draft.revision, before: before, after: after,
                                            requestedAt: ISO8601DateFormatter().string(from: now),
                                            seed: self.seed?.text, window: screen?.window)
                var input = SuggestionRequest(target: target, sources: sources)
                input.association = .explicitRecentRequest
                let selection = SourceSelector.select(input, limits: .window)
                let addition = HeardSpeech.addition(heard, to: selection.selected, members: { context?.rows(for: [$0]) ?? [] }, limits: .window)
                let selected = addition.selected
                let usage = SuggestionHistoryEntry.usage(selected: selected, excluded: selection.excluded)
                self.updateReceipt { receipt in
                    receipt.selected = usage.selected
                    receipt.excluded = usage.excluded
                    if addition.duplicateSpeechCount > 0 {
                        let existing = receipt.excluded.firstIndex { $0.reason == .duplicate }
                        if let existing {
                            let prior = receipt.excluded.remove(at: existing)
                            receipt.excluded.append(.init(reason: .duplicate, count: prior.count + addition.duplicateSpeechCount))
                        } else { receipt.excluded.append(.init(reason: .duplicate, count: addition.duplicateSpeechCount)) }
                    }
                    if addition.overLimitSpeechCount > 0 {
                        let existing = receipt.excluded.firstIndex { $0.reason == .overLimit }
                        if let existing {
                            let prior = receipt.excluded.remove(at: existing)
                            receipt.excluded.append(.init(reason: .overLimit, count: prior.count + addition.overLimitSpeechCount))
                        } else { receipt.excluded.append(.init(reason: .overLimit, count: addition.overLimitSpeechCount)) }
                    }
                    receipt.excluded.sort { $0.reason.rawValue < $1.reason.rawValue }
                }
                self.usedScreen = selected.contains { $0.kind == ScreenContext.kind }
                self.usedSpeech = selected.contains { $0.kind == "dictation" || $0.kind == "meeting-transcript" }
                self.usedHeard = selected.contains { $0.kind == HeardSpeech.kind }
                self.usedAgent = selected.contains { $0.kind == AgentContext.kind }
                if self.usedAgent {
                    self.agentSnapshot = selected.filter { $0.kind == AgentContext.kind }
                    self.agentLatestID = agentSources.last?.id
                }
                self.rows = Array(Dictionary(uniqueKeysWithValues: ((context?.rows(for: selected) ?? []) + (self.usedHeard ? heard?.rows ?? [] : [])).map { ($0.id, $0) }).values)
                // A reply needs something to answer. A continuation needs something to draw on: with only the user's text,
                // the on-device model invents what comes next. The window image counts: it may show what Accessibility missed.
                if selected.isEmpty && image == nil {
                    if mode == .reply { self.showNotice(Self.needsNotes, reason: "no-context"); return }
                    if mode == .continuation {
                        self.showNotice("No suggestion: Jot has nothing from the last few minutes to continue from.", reason: "no-context")
                        return
                    }
                }
                // The conversation id ranked the sources; it is an opaque session id and says nothing to the model.
                var prompted = input; prompted.target.conversation = nil
                let textRequest = SuggestionPrompt.request(for: prompted, sources: selected)
                let request = image == nil ? textRequest : SuggestionPrompt.addingWindowImage(to: textRequest)
                let deadline = Self.deadline(for: mode)
                self.updateReceipt {
                    $0.deadlineMilliseconds = mode == .reply ? 3_000 : 8_000
                    $0.generationStartedAt = Date()
                }
                let generator: ModelCallGate.Generator
                if let image {
                    generator = { try await AppleFMGeneration.generate($0, image: image, textOnly: textRequest) }
                } else {
                    generator = { try await AppleFMGeneration.generate($0) }
                }
                let result = await self.gate.call(request, deadline: deadline, generator: generator)
                guard self.isCurrent(token, field: field) else { return }
                self.updateReceipt { receipt in
                    if let began = receipt.generationStartedAt {
                        receipt.generationMilliseconds = min(60_000, max(0, Int(Date().timeIntervalSince(began) * 1_000)))
                    }
                }
                let expectedRows = self.rows
                if !expectedRows.isEmpty, let store {
                    let current = try await Task.detached { try store.suggestionRowsUnchanged(expectedRows) }.value
                    guard self.isCurrent(token, field: field) else { return }
                    guard current else {
                        self.updateReceipt { $0.reason = .sourcesChanged }
                        self.dismiss(action: .sourcesChanged); self.reason = "sources-changed"; self.notice("Suggestion dismissed because its sources changed."); return
                    }
                }
                switch result {
                case .output(let raw):
                    switch SuggestionOutput.process(raw, mode: mode, singleLine: field.role != kAXTextAreaRole) {
                    case .suggestion(let output):
                        let text = mode == .continuation ? SuggestionOutput.continuation(output, before: before) : output
                        let review = text.isEmpty ? .unchanged : SuggestionOutput.review(text, draft: field.draft, seed: self.seed?.text,
                                                                                         placeholder: field.placeholder, context: excerpt)
                        switch review {
                        case .accept: break
                        case .unchanged:
                            self.showNotice(mode == .continuation ? "No suggestion: the result only repeated your text."
                                                                  : "Your selection already reads well. No changes suggested.", reason: "unchanged")
                            return
                        case .restatesHint:
                            self.showNotice(field.draft.isBlank ? Self.needsNotes : "No suggestion: the result only repeated the field's hint.",
                                            reason: "restates-hint")
                            return
                        case .copiesContext:
                            self.showNotice("No suggestion: the result only repeated text on screen.", reason: "copies-context"); return
                        }
                        self.candidate = text; self.outcome = "ready"
                        self.updateReceipt {
                            $0.outcome = .ready
                            $0.previewMilliseconds = min(60_000, max(0, Int(Date().timeIntervalSince($0.startedAt) * 1_000)))
                        }
                        self.input.showSuggestionKeys(.ready)
                        guard let frame = self.input.targetFrame(timeout: 0.005) else { self.dismiss(action: .focusChanged); return }
                        let title: String, action: String
                        if let seed = self.seed {
                            title = seed.isSelection ? "Rewrite of your selection" : "Draft from your notes"
                            action = seed.isSelection ? "Tab to replace the selection" : "Tab to replace your notes"
                        } else if mode == .continuation {
                            title = "Suggested continuation"; action = "Tab to insert at the cursor"
                        } else { title = "Suggested reply"; action = "Tab to insert" }
                        self.card.show(text: text.trimmingCharacters(in: .whitespaces), title: title,
                                       sources: SuggestionAttribution.line(plan: plan, selected: selected,
                                                                           sessionTitle: context?.sessionTitle,
                                                                           windowImage: image != nil),
                                       action: action, ready: true, at: frame)
                    case .abstained(let detail), .rejected(let detail):
                        let text: String
                        switch mode {
                        case .draft: text = "No suggestion for this selection."
                        case .continuation: text = "No suggestion: nothing to add from your text and this context."
                        case .reply, .shellCommand: text = "No suggestion from this context."
                        }
                        self.showNotice(text, reason: detail)
                    }
                case .unavailable: self.showNotice("No suggestion: Apple Intelligence is unavailable.", reason: "model-unavailable")
                case .timedOut: self.showNotice("No suggestion: the model took too long.", reason: "timed-out")
                case .blocked: self.showNotice("No suggestion: the previous request is still ending.", reason: "blocked")
                case .failed: self.showNotice("No suggestion: the model could not complete the request.", reason: "model-failed")
                case .cancelled: self.dismiss(action: .serviceStopped)
                }
            } catch {
                guard token == self.generation else { return }
                self.showNotice("No suggestion: local context could not be read.", reason: "context-unreadable")
            }
        }
    }


    /// Where to take this request's window image, or nil with the reason recorded. The image is optional: without
    /// permission, image support or the field's window, the request goes on with text alone. Screen Recording is asked
    /// for only when the setting is turned on, never here.
    private func windowImageCapture() -> WindowImageCapture? {
        let skipped: SuggestionHistoryEntry.WindowImageOutcome
        if !WindowImageCapture.permitted { skipped = .noPermission }
        else if !AppleFMGeneration.acceptsImages { skipped = .unsupported }
        else if let capture = input.windowImageCapture() { return capture }
        else { skipped = .noWindow }
        windowImage = skipped.rawValue
        updateReceipt { $0.windowImage = skipped }
        return nil
    }

    /// The notes a draft would rewrite; nil for a blank field, which gets a reply instead.
    private static func draftNotes(in field: DictationInput.SuggestionField) -> String? {
        guard case .draft(let seed) = SuggestionPlan.make(draft: field.draft, role: field.role, hasAssociatedContext: false) else {
            return nil
        }
        return seed.text
    }

    /// Speech Jot heard within the context window that the notes quote or paraphrase. Runs off the main thread; a store that
    /// cannot be read adds nothing rather than failing the draft.
    nonisolated private static func heardSpeech(matching notes: String?, in store: TranscriptStore?, now: Date, window: TimeInterval) -> HeardSpeech.Match? {
        guard let notes, let store, let rows = try? store.heardRows(now: now, lookback: min(window, HeardSpeech.lookback)) else { return nil }
        return HeardSpeech.match(notes: notes, rows: rows)
    }

    /// The longest a request waits for its window image. A later image is dropped and the request goes on with text alone.
    private static let windowImageBudget: Duration = .seconds(1)

    /// A draft or a continuation can run to several sentences; the on-device model needs longer for them than for a one-line reply.
    private static func deadline(for mode: SuggestionMode) -> Duration { mode == .draft || mode == .continuation ? .seconds(8) : .seconds(3) }

    private static func purpose(of field: DictationInput.SuggestionField) -> String {
        guard field.role == kAXTextAreaRole else { return "single-line" }
        return field.bundleID == "com.openai.codex" ? "agent-prompt" : "text-entry"
    }

    /// `stillWanted`, then the field itself, read on the main actor. The request and acceptance paths use this once each.
    private func isCurrent(_ token: Int, field: DictationInput.SuggestionField) -> Bool {
        guard stillWanted(token) else { return false }
        guard input.suggestionFieldIsCurrent(field) else { dismiss(action: .focusChanged); return false }
        return true
    }

    /// The checks that need no Accessibility call: this request is still the latest, its agent sources are unchanged,
    /// and suggestions are still allowed on this keyboard.
    private func stillWanted(_ token: Int) -> Bool {
        guard token == generation, !Task.isCancelled else { return false }
        if let agentLatestID, !agentContext.matchesSnapshot(agentSnapshot, latestID: agentLatestID, within: window()) {
            updateReceipt { $0.reason = .sourcesChanged }
            dismiss(action: .sourcesChanged); return false
        }
        guard allowed(), keyboardAllowsSuggestions else { dismiss(action: .focusChanged); return false }
        return true
    }

    /// While a card is up: four times a second, the field is read again off the main actor and the card follows it or
    /// goes away. The rows behind the card are checked once a second, on the store's executor; acceptance checks them
    /// again before inserting anyway.
    private func monitor(field: DictationInput.SuggestionField, token: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            let expires = ContinuousClock.now.advanced(by: .seconds(30))
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.stillWanted(token) else { return }
                guard ContinuousClock.now < expires else { self.dismiss(action: .expired); return }
                let frame = await self.input.observeSuggestionField(field)
                guard token == self.generation else { return }
                guard let frame else { self.dismiss(action: .focusChanged); return }
                self.card.place(at: frame)
                ticks += 1
                let expectedRows = self.rows
                if ticks % 4 == 0, !expectedRows.isEmpty, let store = self.store() {
                    let current = await Task.detached { (try? store.suggestionRowsUnchanged(expectedRows)) == true }.value
                    guard token == self.generation else { return }
                    if !current {
                        self.updateReceipt { $0.reason = .sourcesChanged }
                        self.dismiss(action: .sourcesChanged); return
                    }
                }
            }
        }
    }

    /// A request Jot cannot take right now: the reason shows at the field for a moment, or in the window when there is no field.
    func refuse(_ text: String, anchorToField: Bool = true) {
        dismiss(action: .newRequest)
        beginReceipt()
        updateReceipt { $0.outcome = .blocked; $0.reason = .refused }
        guard anchorToField else {
            updateReceipt { $0.complete = true }
            notice(text)
            return
        }
        do { try input.captureTarget(wakeRetry: false) } catch { dismiss(action: .focusChanged); notice(text); return }
        ownsTarget = true
        showNotice(text, reason: "refused")
        updateReceipt { $0.outcome = .blocked }
    }

    private func showNotice(_ text: String, reason: String) {
        outcome = "no-suggestion"; self.reason = reason; candidate = nil
        updateReceipt { $0.outcome = .noSuggestion; $0.reason = .init(code: reason) }
        input.showSuggestionKeys(.notice)
        guard let frame = input.targetFrame(timeout: 0.005) else { dismiss(action: .focusChanged); notice(text); return }
        card.show(text: text, at: frame)
        let token = generation
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.dismiss(action: .expired)
        }
    }

    func accept() {
        guard let field, let text = candidate, input.suggestionState == .accepting else { dismiss(action: .focusChanged); return }
        let token = generation, expectedRows = rows, seed = self.seed
        let store = expectedRows.isEmpty ? nil : self.store()
        guard expectedRows.isEmpty || store != nil else {
            updateReceipt { $0.reason = .sourcesChanged }
            dismiss(action: .sourcesChanged); return
        }
        monitorTask?.cancel(); card.hide()
        requestTask = Task { [weak self] in
            guard let self else { return }
            let current = await Task.detached { () -> Bool in
                guard !expectedRows.isEmpty else { return true }
                return (try? store?.suggestionRowsUnchanged(expectedRows)) == true
            }.value
            guard self.isCurrent(token, field: field), current else {
                if token == self.generation { self.dismiss(action: current ? .focusChanged : .sourcesChanged) }
                self.notice("Nothing inserted: the field or its sources changed."); return
            }
            do {
                let result: DictationInput.DeliveryResult
                if let seed { result = try await self.input.replace(seed, with: text, expected: field) }
                else { result = try await self.input.insert(text, expected: field) }
                if result.verified {
                    self.insertions += 1; self.outcome = "inserted"
                    self.updateReceipt { $0.outcome = .inserted }
                    self.dismiss(action: .acceptedVerified)
                } else {
                    self.outcome = "insertion-unverified"
                    self.updateReceipt { $0.outcome = .insertionUnverified; $0.reason = .insertionUnverified }
                    self.dismiss(action: .acceptedUnverified)
                    self.notice("Insertion could not be verified. Check the field before retrying.")
                }
            } catch DictationInput.InputError.selectionUnavailable {
                self.outcome = "selection-unavailable"
                self.updateReceipt { $0.outcome = .insertionCancelled; $0.reason = .selectionUnavailable }
                self.dismiss(action: .focusChanged)
                self.notice(DictationInput.InputError.selectionUnavailable.localizedDescription)
            } catch {
                self.outcome = "insertion-cancelled"
                self.updateReceipt { $0.outcome = .insertionCancelled; $0.reason = .insertionCancelled }
                self.dismiss(action: .focusChanged)
                self.notice("Nothing inserted: the target changed.")
            }
        }
    }
}
