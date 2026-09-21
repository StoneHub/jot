import Foundation

/// Why a dictation shortcut press cannot start right now, in words the notice can show.
public enum DictationReadiness {
    public static func blocker(phase: ServiceLifecycle.Phase, modelsReady: Bool, ambientEnabled: Bool,
                               pauseRequested: Bool, dictationPending: Bool, dictationActive: Bool,
                               diagnosticActive: Bool) -> String? {
        if pauseRequested || phase == .pausing { return "Jot is pausing. Wait for it to finish, then Resume." }
        if phase == .paused || phase == .failed { return "Jot is paused. Choose Resume to dictate." }
        if phase == .starting || !modelsReady { return "Jot is still loading. Try again in a moment." }
        if !ambientEnabled { return "The microphone is off. Choose Resume to start it." }
        if diagnosticActive { return "Wait for the file diagnostic to finish." }
        if dictationPending { return "The last dictation is still being inserted. Try again in a moment." }
        if dictationActive { return "Dictation is already running." }
        return nil
    }
}
