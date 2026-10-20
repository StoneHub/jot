import AppKit
import AVFoundation
import Foundation
import JotCore

/// Microphone, Accessibility and Screen Recording: asking for them, the banner naming what is off, and the settings panes.
/// `refreshPermissions` and `refreshCapabilities` stay in the class, since they write its own published state.
extension SpeechService {
    func requestMic() async -> Bool {
        switch dependencies.microphoneAuthorization() {
        case .authorized: refreshPermissions(); return true
        case .notDetermined:
            let granted = await dependencies.requestMicrophoneAccess()
            refreshPermissions()
            return granted
        default:
            refreshPermissions()
            notice = "Microphone access is required. Enable Jot in System Settings → Privacy & Security → Microphone."
            return false
        }
    }

    /// Only the Fn shortcut and suggestions read keys and fields. Someone who only listens never needs Accessibility, so it is
    /// neither asked for nor reported missing until one of them is on.
    var accessibilityWanted: Bool { dictationRequested || suggestionsEnabled }
    var accessibilityMissing: Bool { accessibilityWanted && !accessibilityGranted }

    var permissionsMissing: Bool { micPermission != .authorized || accessibilityMissing }

    /// Sentence for the persistent banner, naming exactly what is still off.
    var missingPermissionText: String {
        var names: [String] = []
        if micPermission != .authorized { names.append("Microphone") }
        if accessibilityMissing { names.append("Accessibility") }
        return names.joined(separator: " and ") + " access is off."
    }

    /// Startup asks once for whatever is missing and wanted. macOS shows its own dialogs, each with an Open System Settings button.
    func promptForPermissionsAtLaunch() {
        Task {
            if micPermission == .notDetermined { _ = await requestMic() }
            if accessibilityWanted && !DictationInput.accessibilityGranted { input.requestAccessibility() }
            refreshPermissions()
        }
    }

    /// The persistent button. Asks again where macOS still allows it, otherwise opens the exact settings pane.
    func fixPermissions() {
        if micPermission != .authorized { fixMicrophonePermission(); return }
        fixAccessibilityPermission()
    }

    /// Asks for the microphone while macOS still allows asking, otherwise opens its settings pane. Setup's microphone page uses it too.
    func fixMicrophonePermission() {
        if micPermission == .notDetermined { Task { _ = await requestMic() }; return }
        openSettings("Privacy_Microphone")
    }

    /// macOS's own Accessibility prompt the first time, which lists Jot and has its own Open System Settings button. After
    /// that, the pane where Jot is switched on, so one click never shows the prompt and the pane together. Setup's dictation
    /// page uses it too.
    func fixAccessibilityPermission() {
        if !input.accessibilityPrompted { input.requestAccessibility(); return }
        openSettings("Privacy_Accessibility")
    }

    func openScreenRecordingSettings() { openSettings("Privacy_ScreenCapture") }
    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
