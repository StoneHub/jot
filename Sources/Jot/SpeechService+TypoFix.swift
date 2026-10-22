import Foundation
import JotCore

/// Fix typos: when the shortcut is live, what can refuse a press, and what `jot status` reports. The work itself is
/// `TypoFixCoordinator`'s.
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
