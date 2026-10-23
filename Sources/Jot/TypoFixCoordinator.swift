import AppKit
import ApplicationServices
import JotCore

/// Fix typos: on an explicit shortcut press, reads the focused field once, asks the cleanup model to fix typing mistakes in
/// the selection or, with none, the whole field, and replaces only the stretch from the first fix to the last through the
/// checked insertion path. Pressing again while it runs cancels; pressing again within 30 seconds of a fix, on the
/// unchanged field, puts the original back. That original stays in memory until then. No field or model text is saved,
/// logged or counted.
@MainActor
final class TypoFixCoordinator {
    private let input: DictationInput
    private let model: ChosenModel
    private let countUsage: ([UsageCounter]) -> Void
    private let notice: (String) -> Void
    private let shortcutName: () -> String
    private let card = SuggestionCard()
    private let gate = ModelCallGate(deadline: .seconds(30))
    private var task: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
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

    /// Counts and codes only; never field or model text.
    var diagnostics: [String: Any] { ["requests": requests, "fixes": fixes, "outcome": outcome, "reason": reason,
                                      "running": task != nil, "undoAvailable": undo != nil, "model": model.displayName] }

    init(input: DictationInput, model: ChosenModel, countUsage: @escaping ([UsageCounter]) -> Void,
         shortcutName: @escaping () -> String, notice: @escaping (String) -> Void) {
        self.input = input; self.model = model; self.countUsage = countUsage
        self.shortcutName = shortcutName; self.notice = notice
    }
    isolated deinit { task?.cancel(); hideTask?.cancel() }

    /// The shortcut. `blocker` is why Jot cannot take a request now, in the words the card shows.
    func press(blocker: String?) {
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
        let running = task != nil
        reset()
        if running { record(.cancelled) }
    }

    private func reset() {
        generation += 1
        task?.cancel(); task = nil
        hideTask?.cancel(); hideTask = nil
        gate.cancel()
        card.hide()
        frame = nil
        if ownsTarget { ownsTarget = false; input.clearTarget() }
    }

    /// The user went on typing, focus left the field, or a dictation began before the fix was written.
    func interrupted() {
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
        let draft = field.draft
        let selected = draft.length > 0 && !draft.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = selected ? draft.selectedText : draft.value
        let offset = selected ? draft.location : 0
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !draft.isBlank else {
            finish(.empty, "Nothing to fix here.")
            return
        }
        guard (text as NSString).length <= TypoFixPrompt.maximumCharacters else {
            finish(.oversized, "Too long to fix at once. Select a part, up to about 3,000 characters, and press \(shortcutName()) again.")
            return
        }
        show("Fixing typos…", action: "\(shortcutName()) again to cancel", loading: true)
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
            fixes += 1
            if let fixedValue {
                undo = Undo(pid: target.pid, field: target.field, edit: edit, fixedValue: fixedValue,
                            expires: ContinuousClock.now.advanced(by: Self.undoWindow))
            }
            finish(.fixed, changes == 1 ? "Fixed 1 typo." : "Fixed \(changes) typos.", action: "\(shortcutName()) within 30 s to undo")
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

    private func record(_ result: TypoFixOutcome) {
        outcome = result.rawValue
        if result != .rejected { reason = "none" }
        countUsage([.typoFix(result)])
    }

    /// Records how the press ended and shows why at the field for a moment, or as a notice when there is no field.
    private func finish(_ result: TypoFixOutcome, _ text: String, action: String = "") {
        record(result)
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
}
