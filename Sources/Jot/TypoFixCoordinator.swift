import AppKit
import ApplicationServices
import JotCore

/// Fix typos: on an explicit shortcut press, reads the focused field once, asks the cleanup model to fix typing mistakes in
/// the selection or, with none, the whole field, and replaces only the stretch from the first fix to the last through the
/// checked insertion path. Pressing again while it runs cancels; pressing again within 30 seconds of a fix, on the
/// unchanged field, puts the original back. That original stays in memory until then. No field or model text is saved,
/// logged or counted.
///
/// The first double-tap of Fn in a field with text runs the same check as a preview (`check(then:)`): the fixes show on the
/// card and Tab writes them. A second double-tap on that field goes on to a suggestion, whether Tab was pressed or not.
@MainActor
final class TypoFixCoordinator {
    private let input: DictationInput
    private let model: ChosenModel
    private let countUsage: ([UsageCounter]) -> Void
    private let notice: (String) -> Void
    /// The live Fix typos shortcut's name, or nil while it is off or its key belongs to another shortcut.
    private let shortcutName: () -> String?
    private let card = SuggestionCard()
    private let gate = ModelCallGate(deadline: .seconds(30))
    private var task: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var generation = 0
    private var ownsTarget = false { didSet { input.typoFixOwnsTarget = ownsTarget } }
    private var frame: CGRect?
    private var undo: Undo?
    private var requests = 0
    private var fixes = 0
    /// The last press's outcome and, for a rejected result, which check refused it. Codes only.
    private var outcome = "idle"
    private var reason = "none"

    /// The fix just written, so a second press can reverse it. Only while its field still holds exactly the fixed value.
    private struct Undo {
        let pid: pid_t
        let field: AXUIElement
        let edit: TypoFixEdit
        let fixedValue: String
        let expires: ContinuousClock.Instant
    }
    private static let undoWindow: Duration = .seconds(30)

    // MARK: Double-Fn preview state

    /// Where a double-Fn check is. Nil while none runs, including during a shortcut press.
    private enum Phase {
        case checking
        case showing(Preview)
        case applying
    }
    /// A checked fix on the card, waiting for Tab.
    private struct Preview {
        let edit: TypoFixEdit
        let field: DictationInput.SuggestionField
        let changes: Int
    }
    /// The field the last double-Fn check read, and a hash of its text so no copy of it is kept. The next request on that
    /// field, while it still hashes the same, goes straight to a suggestion. Typing, a click or another app ends it.
    private struct Step {
        let pid: pid_t
        let field: AXUIElement
        let valueHash: Int
    }
    private var phase: Phase?
    private var step: Step?
    private var suggest: (() -> Void)?
    /// A check the model was asked for and whose outcome is not counted yet.
    private var previewCounted = false
    private var previewChecks = 0
    private var previewOutcome = "idle"
    private static let previewFooter = "Tab to fix · double-tap Fn for a suggestion · Esc to dismiss"
    /// The double-Fn check stands between the user and a suggestion, so it takes less text and less time than a press.
    private static let previewMaximumCharacters = 800
    private static let previewDeadline: Duration = .seconds(8)

    /// Counts and codes only; never field or model text.
    var diagnostics: [String: Any] { ["requests": requests, "fixes": fixes, "outcome": outcome, "reason": reason,
                                      "running": task != nil, "undoAvailable": undo != nil, "model": model.displayName,
                                      "previewChecks": previewChecks, "previewOutcome": previewOutcome, "previewShowing": showsPreview] }

    /// A double-Fn preview is on the card, so Tab is the preview's.
    var showsPreview: Bool {
        if case .showing = phase { return true }
        return false
    }

    init(input: DictationInput, model: ChosenModel, countUsage: @escaping ([UsageCounter]) -> Void,
         shortcutName: @escaping () -> String?, notice: @escaping (String) -> Void) {
        self.input = input; self.model = model; self.countUsage = countUsage
        self.shortcutName = shortcutName; self.notice = notice
    }
    isolated deinit { task?.cancel(); hideTask?.cancel(); monitorTask?.cancel() }

    /// The shortcut. `blocker` is why Jot cannot take a request now, in the words the card shows.
    func press(blocker: String?) {
        endPreview()
        if task != nil { stop(); return }
        reset()
        requests += 1
        countUsage([.typoFixRequested])
        if let blocker {
            // Shown at the field when there is one, unless a dictation holds it: capturing would take the hold's field.
            if !input.dictationOwnsTarget, (try? input.captureTarget()) != nil {
                ownsTarget = true
                frame = input.targetFrame(timeout: 0.005)
            }
            finish(.blocked, blocker)
            return
        }
        do { try input.captureTarget() } catch {
            finish(.unreadableField, "Fix typos: click into a text field first.")
            return
        }
        ownsTarget = true
        frame = input.targetFrame(timeout: 0.005)
        let token = generation
        task = Task { [weak self] in
            await self?.run(token: token)
            if let self, token == self.generation { self.task = nil }
        }
    }

    /// Ends a request in flight, counted as cancelled, and hides the card without a notice: a second press, a suggestion or
    /// a setting took over.
    func stop() {
        if endPreview() { return }
        let running = task != nil
        reset()
        if running { record(.cancelled) }
    }

    private func reset() {
        generation += 1
        task?.cancel(); task = nil
        hideTask?.cancel(); hideTask = nil
        monitorTask?.cancel(); monitorTask = nil
        gate.cancel()
        card.hide()
        frame = nil
        suggest = nil
        // A double-Fn check holds the suggestion keys for Escape and Tab; give them back.
        if phase != nil { phase = nil; input.dismissSuggestionKeys() }
        if ownsTarget { ownsTarget = false; input.clearTarget() }
    }

    /// The user went on typing, focus left the field, or a dictation began before the fix was written.
    func interrupted() {
        if endPreview() { return }
        guard task != nil else { return }
        reset()
        record(.fieldChanged)
    }

    private func run(token: Int) async {
        let read = await input.readSuggestionField()
        guard token == generation else { return }
        guard let field = read else {
            finish(.unreadableField, "This field can't be read safely, so Jot left it alone.")
            return
        }
        if let undo = takeUndo(for: field) {
            await apply(undo.edit.reversed, field: field, token: token, undoing: true, changes: 0)
            return
        }
        guard let scope = Self.scope(of: field.draft) else {
            finish(.empty, "Nothing to fix here.")
            return
        }
        let text = scope.text, offset = scope.offset
        guard (text as NSString).length <= TypoFixPrompt.maximumCharacters else {
            finish(.oversized, "Too long to fix at once. Select a part, up to about 3,000 characters, and press \(shortcutName() ?? "the shortcut") again.")
            return
        }
        show("Fixing typos…", action: "\(shortcutName() ?? "The shortcut") again to cancel", loading: true)
        let model = self.model
        let result = await gate.call(TypoFixPrompt.request(for: text), deadline: TypoFixPrompt.deadline(for: text)) {
            try await model.generate($0)
        }
        guard token == generation else { return }
        switch result {
        case .output(let raw):
            let review = await Task.detached(priority: .userInitiated) { TypoFixReview.review(raw, source: text) }.value
            guard token == generation else { return }
            switch review {
            case .unchanged:
                finish(.unchanged, "No typos found.")
            case .rejected(let code):
                reason = code
                finish(.rejected, "The model changed more than typos, so Jot left your text as it was.")
            case .fixed(let corrected, let changes):
                guard let edit = TypoFixEdit(source: text, corrected: corrected, offset: offset) else {
                    finish(.unchanged, "No typos found."); return
                }
                await apply(edit, field: field, token: token, undoing: false, changes: changes)
            }
        case .timedOut:
            finish(.timedOut, "Fixing typos took too long. Try a shorter selection.")
        case .unavailable:
            finish(.unavailable, "The model is unavailable right now, so nothing changed.")
        case .blocked:
            finish(.blocked, "The last fix is still finishing. Try again in a moment.")
        case .failed:
            finish(.failed, "The model could not fix this text, so nothing changed.")
        case .cancelled:
            break
        }
    }

    /// The text a fix covers and where it starts in the field: the selection when it has text, otherwise the whole field.
    /// Nil when that is blank.
    private static func scope(of draft: SuggestionDraftSnapshot) -> (text: String, offset: Int)? {
        let selected = draft.length > 0 && !draft.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = selected ? draft.selectedText : draft.value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !draft.isBlank else { return nil }
        return (text, selected ? draft.location : 0)
    }

    /// Selects exactly the edit's original text and inserts its replacement, through the same verified path as dictation
    /// and suggestions. Nothing is written when the field no longer holds what was read.
    private func apply(_ edit: TypoFixEdit, field: DictationInput.SuggestionField, token: Int, undoing: Bool, changes: Int) async {
        guard let target = input.target else { finish(.fieldChanged, "Focus moved, so nothing changed."); return }
        let fixedValue = edit.applied(to: field.draft.value)
        do {
            let result = try await input.replace(edit.seed, with: edit.replacement, expected: field)
            // Insertion lets go of the field when it finishes.
            ownsTarget = false
            guard token == generation else { return }
            guard result.verified else {
                finish(.insertionUnverified, "Jot couldn't confirm the change. Check the field.")
                return
            }
            if undoing {
                finish(.undone, "Your original text is back.")
                return
            }
            if phase == nil { fixes += 1 }
            if let fixedValue {
                undo = Undo(pid: target.pid, field: target.field, edit: edit, fixedValue: fixedValue,
                            expires: ContinuousClock.now.advanced(by: Self.undoWindow))
                // The next double-Fn on this field asks for a suggestion rather than checking the fixed text again.
                if phase != nil { step = Step(pid: target.pid, field: target.field, valueHash: fixedValue.hashValue) }
            }
            finish(.fixed, changes == 1 ? "Fixed 1 typo." : "Fixed \(changes) typos.",
                   action: shortcutName().map { "\($0) within 30 s to undo" } ?? "")
        } catch DictationInput.InputError.selectionUnavailable {
            ownsTarget = false
            guard token == generation else { return }
            finish(.selectionUnavailable, "This field didn't let Jot select the text, so nothing changed.")
        } catch {
            ownsTarget = false
            guard token == generation else { return }
            finish(.fieldChanged, "The field changed before Jot could fix it, so nothing changed.")
        }
    }

    /// The last fix, when this press is on the same field, still showing exactly the fixed text, within the undo window.
    /// Any press uses it up, so a later press fixes typos again.
    private func takeUndo(for field: DictationInput.SuggestionField) -> Undo? {
        defer { undo = nil }
        guard let undo, ContinuousClock.now < undo.expires, let target = input.target, target.pid == undo.pid,
              CFEqual(target.field, undo.field), field.draft.value == undo.fixedValue else { return nil }
        return undo
    }

    /// A shortcut press's outcome, or, for the write that Tab started on a preview, the preview's.
    private func record(_ result: TypoFixOutcome) {
        if phase != nil { recordPreview(result == .fixed ? .applied : .notApplied); return }
        outcome = result.rawValue
        if result != .rejected { reason = "none" }
        countUsage([.typoFix(result)])
    }

    /// Records how the press ended and shows why at the field for a moment, or as a notice when there is no field.
    private func finish(_ result: TypoFixOutcome, _ text: String, action: String = "") {
        record(result)
        if phase != nil { phase = nil; input.dismissSuggestionKeys() }
        let place = frame ?? input.targetFrame(timeout: 0.005)
        if ownsTarget { ownsTarget = false; input.clearTarget() }
        guard let place else { card.hide(); notice(text); return }
        frame = place
        show(text, action: action, loading: false)
        let token = generation
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(action.isEmpty ? 2.5 : 4))
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.card.hide(); self.frame = nil
        }
    }

    private func show(_ text: String, action: String, loading: Bool) {
        guard let frame else { return }
        card.show(text: text, title: "Fix typos", loading: loading, footer: action, at: frame)
    }

    // MARK: Double-Fn preview

    /// Double-tap Fn, or the extra suggestion shortcut, with Fix typos on. In a field with text, the first request checks
    /// typos and shows the fixes for Tab. Anything else goes to `suggest`: a blank or oversized field, a field the check
    /// cannot read, no typos, a result that changed more than typos, a model that could not answer, and a second request
    /// on the same field, whether it comes while the check runs, while the fixes show, or after Tab or Escape.
    func check(then suggest: @escaping () -> Void) {
        if phase != nil { endPreview(); suggest(); return }
        // A shortcut press still running gives way, counted as cancelled, as it does for a suggestion.
        stop()
        do { try input.captureTarget() } catch { suggest(); return }
        ownsTarget = true
        guard let place = input.targetFrame(timeout: 0.005) else { reset(); suggest(); return }
        frame = place
        phase = .checking
        self.suggest = suggest
        let token = generation
        task = Task { [weak self] in
            await self?.runCheck(token: token)
            if let self, token == self.generation { self.task = nil }
        }
    }

    /// Ends a double-Fn check or its preview without writing anything. False when none was running.
    @discardableResult
    func endPreview() -> Bool {
        guard let phase else { return false }
        let ended: TypoFixPreview.Outcome
        switch phase {
        case .checking: ended = .cancelled
        case .showing: ended = .skipped
        case .applying: ended = .notApplied
        }
        reset()
        recordPreview(ended)
        return true
    }

    /// The user typed, clicked or switched apps: the next double-Fn starts over with a typo check.
    func endSequence() { step = nil }

    /// Tab on the preview: writes the fix through the same checked path as a shortcut press.
    func acceptPreview() {
        guard case .showing(let preview) = phase, input.suggestionState == .accepting else { endPreview(); return }
        phase = .applying
        monitorTask?.cancel(); monitorTask = nil
        card.hide()
        let token = generation
        task = Task { [weak self] in
            await self?.apply(preview.edit, field: preview.field, token: token, undoing: false, changes: preview.changes)
            if let self, token == self.generation { self.task = nil }
        }
    }

    private func runCheck(token: Int) async {
        let read = await input.readSuggestionField()
        guard token == generation else { return }
        guard let field = read, let target = input.target else { handOff(); return }
        let valueHash = field.draft.value.hashValue
        if let step, step.pid == target.pid, CFEqual(step.field, target.field), step.valueHash == valueHash {
            handOff(); return
        }
        step = Step(pid: target.pid, field: target.field, valueHash: valueHash)
        // A selection goes to the rewrite, which replaces it anyway; a long draft would keep the suggestion waiting.
        guard field.draft.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let scope = Self.scope(of: field.draft), (scope.text as NSString).length <= Self.previewMaximumCharacters else {
            handOff(); return
        }
        let text = scope.text, offset = scope.offset
        previewChecks += 1
        previewCounted = true
        countUsage([.typoFixPreviewRequested])
        input.showSuggestionKeys(.loading)
        show("Checking typos…", action: "Esc to cancel · double-tap Fn for a suggestion", loading: true)
        let model = self.model
        let result = await gate.call(TypoFixPrompt.request(for: text), deadline: min(TypoFixPrompt.deadline(for: text), Self.previewDeadline)) {
            try await model.generate($0)
        }
        guard token == generation else { return }
        switch result {
        case .output(let raw):
            let (review, summary) = await Task.detached(priority: .userInitiated) { () -> (TypoFixReview.Result, String) in
                let review = TypoFixReview.review(raw, source: text)
                guard case .fixed(let corrected, _) = review else { return (review, "") }
                return (review, TypoFixPreview.summary(source: text, corrected: corrected))
            }.value
            guard token == generation else { return }
            switch review {
            case .unchanged:
                handOff(.noTypos)
            case .rejected:
                handOff(.rejected)
            case .fixed(let corrected, let changes):
                guard let edit = TypoFixEdit(source: text, corrected: corrected, offset: offset) else { handOff(.noTypos); return }
                showPreview(Preview(edit: edit, field: field, changes: changes), summary: summary, token: token)
            }
        case .timedOut, .unavailable, .blocked, .failed:
            handOff(.failed)
        case .cancelled:
            break
        }
    }

    /// Ends the check with nothing to show and goes on to the suggestion.
    private func handOff(_ ended: TypoFixPreview.Outcome? = nil) {
        if let ended { recordPreview(ended) }
        let suggest = self.suggest
        reset()
        suggest?()
    }

    private func showPreview(_ preview: Preview, summary: String, token: Int) {
        guard let frame else { endPreview(); return }
        phase = .showing(preview)
        input.showSuggestionKeys(.ready)
        card.show(text: summary.isEmpty ? "Jot found typos in this field." : summary,
                  title: preview.changes == 1 ? "Fix 1 typo?" : "Fix \(preview.changes) typos?",
                  footer: Self.previewFooter, at: frame)
        monitorPreview(preview.field, token: token)
    }

    /// While the fixes show: four times a second, the field is read again off the main actor, and the card follows it or
    /// goes away when the field, its text or the card's keys changed, or after 30 seconds.
    private func monitorPreview(_ field: DictationInput.SuggestionField, token: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            let expires = ContinuousClock.now.advanced(by: .seconds(30))
            var requested = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, token == self.generation, self.showsPreview else { return }
                guard ContinuousClock.now < expires else { self.endPreview(); return }
                // Tab moves the keys to accepting, and a second request to requesting, before the main actor hears about
                // it; the request ends the preview itself, and a request dropped on the way ends it here a tick later.
                let keys = self.input.suggestionState
                if keys == .requesting && !requested { requested = true; continue }
                guard keys == .ready || keys == .accepting else { self.endPreview(); return }
                let place = await self.input.observeSuggestionField(field)
                guard token == self.generation, self.showsPreview else { return }
                guard let place else { self.endPreview(); return }
                self.frame = place
                self.card.place(at: place)
            }
        }
    }

    /// Counts how a check the model was asked for ended, once.
    private func recordPreview(_ ended: TypoFixPreview.Outcome) {
        guard previewCounted else { return }
        previewCounted = false
        previewOutcome = ended.rawValue
        countUsage([.typoFixPreview(ended)])
    }
}
