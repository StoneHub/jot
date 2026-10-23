import SwiftUI
import JotCore

/// General → Fix typos: the switch and its shortcut.
struct TypoFixSettings: View {
    @ObservedObject var service: SpeechService

    var body: some View {
        SettingsGroup(title: "Fix typos", symbol: "character.cursor.ibeam", beta: true) {
            SettingToggle(title: "Fix typos", info: info, isOn: $service.typoFixEnabled,
                          unavailable: service.typoFixAvailability != .available)
            RowDivider()
            SettingRow(title: "Shortcut", info: "Press it in any text field. Press it again while Jot works to cancel, or within 30 seconds of a fix to put your original text back.",
                       indented: true, enabled: service.typoFixEnabled && service.typoFixAvailability == .available) {
                ShortcutSettings(service: service, purpose: .typoFix)
            }
        }
    }

    private var info: String {
        guard service.typoFixAvailability == .available else {
            return service.typoFixAvailability.typoFixBlocker ?? service.typoFixAvailability.explanation
        }
        return "Fixes misspellings and mistyped words in the selection, or the whole field when nothing is selected, and keeps your wording. "
            + "Jot reads the field only when you press the shortcut and keeps nothing afterward. Uses the cleanup model: "
            + CustomModelSettings.destination(service, usesCustomModel: service.customModelForCleanup)
    }
}
