import Foundation
import JotCore

/// Fix typos: when the shortcut is live, what can refuse a press, how double-tap Fn checks typos before a suggestion,
/// and what `jot status` reports. The work itself is `TypoFixCoordinator`'s.
extension SpeechService {
    /// The shortcut the event tap listens for: nil while Fix typos is off or its key belongs to another shortcut.
    var effectiveTypoFixShortcut: DictationShortcut? {
        guard typoFixEnabled else { return nil }
        return TypoFixShortcutPreferences.effective(typoFixShortcut, others: [shortcut, suggestionShortcut])
    }

    var typoFixAvailability: CleanupAvailability { modelAvailability(.cleanup) }

    /// Why a press cannot be taken right now, in the words the card shows.
    var typoFixBlocker: String? {
        if preparingUpdate { return "Jot is finishing the update." }
        if let reason = typoFixAvailability.typoFixBlocker { return reason }
        if dictation.isActive || dictation.isPending { return "Finish the dictation, then fix typos." }
        if diagnosticActive { return "Fix typos is unavailable while diagnostics run." }
        if !suggestions.keyboardAllowsSuggestions { return "Fix typos works with keyboard layouts, not input methods." }
        return nil
    }

    func typoFixPressed() {
        suggestions.dismiss(action: .newRequest)
        typoFix.press(blocker: typoFixBlocker)
    }

    /// Double-tap Fn, or the extra suggestion shortcut. With Fix typos on and able to run, the first request in a field with
    /// text shows its typo fixes for Tab and the next asks for a suggestion; otherwise every request asks for a suggestion.
    func suggestionRequested() {
        suggestions.dismiss(action: .newRequest)
        guard typoFixEnabled, typoFixBlocker == nil else {
            typoFix.stop()
            suggestions.request()
            return
        }
        typoFix.check { [weak self] in self?.suggestions.request() }
    }

    /// Tab on a ready card: the typo preview's when one shows, otherwise the suggestion's.
    func suggestionAccepted() {
        if typoFix.showsPreview { typoFix.acceptPreview() } else { suggestions.accept() }
    }

    /// Escape, typing, a focus change or a dictation hold ends whichever card is up.
    func suggestionDismissed(_ action: SuggestionHistoryEntry.Action) {
        typoFix.endPreview()
        suggestions.dismiss(action: action)
    }

    /// `jot status` → `typoFix`: the setting, the shortcut and the coordinator's counts. Never text.
    var typoFixStatus: [String: Any] {
        var result = typoFix.diagnostics
        result["enabled"] = typoFixEnabled
        result["shortcut"] = typoFixShortcut.displayName
        result["listening"] = input.typoFixShortcut != nil && input.isEnabled
        result["availability"] = typoFixAvailability.rawValue
        return result
    }
}
