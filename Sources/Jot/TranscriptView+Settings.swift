import SwiftUI
import AppKit
import JotCore

/// A titled card of setting rows; the caller places a RowDivider between rows.
struct SettingsGroup<Rows: View>: View {
    let title: String
    let symbol: String
    var info: String? = nil
    var beta = false
    @ViewBuilder let rows: () -> Rows
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(.tint)
                Text(title).font(.headline)
                if beta {
                    Text("Beta").font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.purple)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: JotTheme.Radius.badge))
                }
                if let info { InfoButton(title: title, detail: info) }
            }.padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .modifier(GroupSurface())
        }
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, JotTheme.Padding.row) }
}

/// A setting's name and (i) on the left and its control on the right, or the control under the name when the row is too narrow for both. An indented row depends on the one above; a row that cannot change dims its name and disables its control, while its (i) still works.
struct SettingRow<Control: View>: View {
    let title: String
    let info: String
    var indented = false
    var enabled = true
    @ViewBuilder let control: () -> Control
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label.fixedSize()
                Spacer(minLength: 12)
                control().disabled(!enabled).layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control().disabled(!enabled)
            }
        }
        .padding(.leading, indented ? 30 : 14).padding(.trailing, 14).padding(.vertical, 8)
        .frame(minHeight: 40)
    }
    private var label: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(enabled ? .primary : .secondary)
            InfoButton(title: title, detail: info)
        }
    }
}

/// A switch row. An unavailable one is disabled and says so beside the switch.
struct SettingToggle: View {
    let title: String
    let info: String
    @Binding var isOn: Bool
    var indented = false
    var enabled = true
    var unavailable = false
    var body: some View {
        SettingRow(title: title, info: info, indented: indented, enabled: enabled && (!unavailable || isOn)) {
            HStack(spacing: 8) {
                if unavailable { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

/// Light, dark or the Mac's choice, and the accent Jot tints with. Both save through JotSettings, so choosing the default leaves no key, and a change from `jot settings` shows here at once.
private struct AppearanceSettings: View {
    @AppStorage(JotDefaultsKey.appearance) private var appearance = JotAppearance.system.rawValue
    @AppStorage(JotDefaultsKey.accentColor) private var accent = JotAccent.system.rawValue
    var body: some View {
        SettingsGroup(title: "Appearance", symbol: "paintpalette") {
            SettingRow(title: "Appearance", info: "System follows the Mac's Light or Dark setting. Light or Dark keeps Jot's windows and panels that way whatever the Mac uses.") {
                Picker("Appearance", selection: Binding(get: { JotAppearance(saved: appearance) }, set: { save(JotDefaultsKey.appearance, $0.rawValue) })) {
                    ForEach(JotAppearance.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            RowDivider()
            SettingRow(title: "Accent color", info: "Tints Jot's buttons, cards and charts. The first choice follows the accent color in System Settings → Appearance.") {
                HStack(spacing: 6) {
                    ForEach(JotAccent.allCases) { option in
                        AccentSwatch(option: option, selected: JotAccent(saved: accent) == option) { save(JotDefaultsKey.accentColor, option.rawValue) }
                    }
                }
            }
        }
    }
    private func save(_ key: String, _ value: String) { try? JotSettings.standard.set(key, value) }
}

/// One accent choice. The Mac's own accent shows as a color wheel, as System Settings draws its multicolor choice.
private struct AccentSwatch: View {
    let option: JotAccent
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            swatch.frame(width: 18, height: 18).padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.55) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain).help(option.title)
        .accessibilityLabel(option.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var swatch: some View {
        if option == .system {
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
        } else {
            Circle().fill(option.color)
        }
    }
}

extension TranscriptView {
    var activity: some View {
        ActivityView(service: service, library: library)
    }

    /// Vorssaint's apps share this bundle prefix; JotControllerPresence matches the same one.
    static var vorssaintRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.vorssaint.utils") == true }
    }

    var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dictationSettings
                suggestionSettings
                CustomModelSettings(service: service)
                recoverySettings
                listeningSettings
                speakerSettings
                AppearanceSettings()
                // The choice only matters next to Vorssaint; once it is off, it stays visible so it can be turned back on.
                if !showMenuBarIcon || Self.vorssaintRunning {
                    SettingsGroup(title: "App", symbol: "menubar.rectangle") {
                        SettingToggle(title: "Always show menu bar icon", info: "When off, Jot hides its icon while Vorssaint shows Jot in its Dynamic Island. The icon returns when that feature is turned off or Vorssaint quits.",
                                      isOn: $showMenuBarIcon)
                    }
                }
            }.frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dictationSettings: some View {
        SettingsGroup(title: "Dictation", symbol: "keyboard", info: "How holding the dictation shortcut behaves. Choose the shortcut in the sidebar.") {
            SettingToggle(title: "Outline target field", info: "A pulsing accent border marks the field your words go into, from pressing the shortcut until the text is inserted.",
                          isOn: $service.highlightTargetField)
            RowDivider()
            SettingToggle(title: "Mute built-in speakers", info: "Mutes the built-in speakers while you hold the shortcut, then restores their previous state. Other outputs are unchanged. Media keeps playing silently.",
                          isOn: $service.muteSpeakersDuringDictation)
            RowDivider()
            SettingToggle(title: cleanupTitle, info: cleanupInfo("Runs a cleanup pass before inserting text. Off is faster."),
                          isOn: $service.cleanUpDictation, unavailable: service.cleanupAvailability != .available)
        }
    }

    private var suggestionSettings: some View {
        SettingsGroup(title: "Suggestions", symbol: "sparkles", info: "Experimental. Review each draft: suggestions can get facts or speaker roles wrong.", beta: true) {
            Text(service.suggestionAvailability.suggestionBlocker ?? (service.customModelForSuggestions ? "Optional drafts from your custom model." : "Optional Apple Intelligence drafts.") + " Double-tap Fn to request; Tab accepts. Turning suggestions off leaves dictation unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
            SettingToggle(title: "Suggestions", info: "Select rough notes in a text field, then double-tap Fn to rewrite them. Without a selection, Jot continues at the cursor. In an empty chat box, it drafts a reply. Typing or Escape dismisses. Nothing is sent unless suggestions use a custom model off this Mac. Works while listening is paused. When off, double-Fn does not insert anything.",
                          isOn: $service.suggestionsEnabled, unavailable: service.suggestionAvailability != .available)
            RowDivider()
            SettingRow(title: "Extra shortcut", info: "Optional. Requests a suggestion, like double-tapping Fn.", indented: true, enabled: service.suggestionsEnabled && service.suggestionAvailability == .available) {
                ShortcutSettings(service: service, forSuggestions: true)
            }
            RowDivider()
            SettingToggle(title: "Read visible conversation", info: "When you ask for a suggestion, reads the text shown above the field in the same window. It is never saved, and stays on this Mac unless suggestions use a custom model off this Mac.",
                          isOn: $service.suggestionScreenContext,
                          indented: true, enabled: service.suggestionsEnabled && service.suggestionAvailability == .available)
            RowDivider()
            SettingToggle(title: "Include window image", info: "Optional. When you ask for a suggestion, also gives the on-device model one image of the window around the field: the part above the field, in its column. It can show messages, an error or a chart that the text misses. It stays in memory for that request and is never saved. Needs Screen Recording permission, asked for when you turn this on, and macOS 27 with a model that takes images.",
                          isOn: $service.suggestionWindowImage,
                          indented: true, enabled: service.suggestionsEnabled && service.suggestionAvailability == .available,
                          unavailable: !service.windowImageSupported)
            if service.suggestionWindowImage && !service.screenRecordingAllowed {
                RowDivider()
                SettingRow(title: "Screen Recording", info: "Allow Jot in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to reopen Jot. Until then, suggestions use text alone.",
                           indented: true) {
                    Button("Open System Settings") { service.openScreenRecordingSettings() }
                }
            }
            RowDivider()
            SettingToggle(title: "Use matching speech", info: "When a selection quotes or paraphrases speech Jot heard within the context window, use the matching sentence to restore missing or misheard words in the rewrite.",
                          isOn: $service.suggestionHeardMatches,
                          indented: true, enabled: service.suggestionsEnabled && service.suggestionAvailability == .available)
            RowDivider()
            SettingRow(title: "Context window", info: "How far back a suggestion may read: speech Jot heard, with the speaker when known, and messages agents sent with `jot context add`. Older speech stays in Sessions; older agent messages are forgotten.",
                       indented: true, enabled: service.suggestionsEnabled && service.suggestionAvailability == .available) {
                Picker("Context window", selection: $service.suggestionWindowMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityIdentifier("suggestion-window")
            }
        }
    }

    private var listeningSettings: some View {
        SettingsGroup(title: "Listening", symbol: "waveform") {
            SettingRow(title: "New session after quiet", info: "Listening starts a new session when nothing is said for this long. A named meeting runs until you end it.") {
                Picker("New session after quiet", selection: $service.newSessionAfterSilence) {
                    ForEach(SessionSplit.choices, id: \.self) { Text(SessionSplit.label($0)).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            RowDivider()
            SettingToggle(title: cleanupTitle, info: cleanupInfo("Makes live speech and meetings more readable. Paused while the Mac is in Low Power Mode."),
                          isOn: $service.cleanUpTranscriptions, unavailable: service.cleanupAvailability != .available)
            RowDivider()
            SettingToggle(title: "Keep audio for speaker pass", info: "Keeps session audio until the speaker pass finishes, then deletes it. When off, audio never touches disk and no speaker pass runs.",
                          isOn: $service.keepAudioForSpeakerPass)
        }
    }

    private var speakerSettings: some View {
        SettingsGroup(title: "Speakers & paragraphs", symbol: "person.2", info: "Speaker settings apply to new audio and to any session you Regroup that has no speaker pass. Paragraph and filler settings also update saved dictations.") {
            presetRow
            RowDivider()
            tuningSlider("Speaker confidence", info: "Higher needs stronger evidence for a speaker label. More speech may stay unlabeled.",
                value: $service.tuning.speakerConfidence, range: 0.45...0.9, step: 0.05,
                valueText: String(format: "%.0f%%", service.tuning.speakerConfidence * 100))
            RowDivider()
            tuningSlider("Minimum speaker turn", info: "Higher ignores brief hesitations. Short real replies may stay with the previous speaker.",
                value: $service.tuning.minimumSpeakerTurn, range: 0.2...2, step: 0.1,
                valueText: String(format: "%.1f s", service.tuning.minimumSpeakerTurn))
            RowDivider()
            tuningSlider("Paragraph pause", info: "Longer pauses make fewer, longer rows, and group nearby dictation rows from the same speaker.",
                value: $service.tuning.paragraphPause, range: 0.3...2.5, step: 0.1,
                valueText: String(format: "%.1f s", service.tuning.paragraphPause))
            RowDivider()
            SettingToggle(title: "Hide filler-only rows", info: "Hides rows that are only um, uh, or hmm. The original text is kept, and fillers inside sentences stay visible.",
                          isOn: $service.tuning.hideFillerRows)
        }
    }

    /// The cleanup explanation, with where the text goes, while its model can run; otherwise why it cannot.
    private func cleanupInfo(_ available: String) -> String {
        guard service.cleanupAvailability == .available else { return service.cleanupAvailability.explanation }
        return available + " " + CustomModelSettings.destination(service, usesCustomModel: service.customModelForCleanup)
    }

    private var cleanupTitle: String {
        service.customModelForCleanup ? "Clean up with custom model" : "Clean up with Apple Intelligence"
    }

    private var recoverySettings: some View {
        SettingsGroup(title: "Saved dictation", symbol: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                Text("If a held dictation could not be inserted, review the saved text and copy it yourself. Works while paused, without Apple Intelligence. Other speech stays in Sessions.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ReviewSavedDictationButton(service: service).modifier(GlassButton())
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Presets as one segmented control; values that match none show Custom and leave every segment unselected.
    private var presetRow: some View {
        SettingRow(title: "Preset", info: "Starting points for the values below. Moving a slider switches to Custom.") {
            HStack(spacing: 8) {
                if TuningPreset.matching(service.tuning) == nil {
                    Text("Custom").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
                // Segments while they fit, a menu when they don't.
                ViewThatFits(in: .horizontal) {
                    presetPicker.pickerStyle(.segmented).fixedSize()
                    presetPicker.pickerStyle(.menu).fixedSize()
                }
            }
        }
    }

    private var presetPicker: some View {
        Picker("Preset", selection: Binding<TuningPreset?>(get: { TuningPreset.matching(service.tuning) }, set: { if let preset = $0 { service.tuning = preset.tuning } })) {
            ForEach(TuningPreset.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }.labelsHidden()
    }

    private func tuningSlider(_ title: String, info: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        SettingRow(title: title, info: info) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(minWidth: 120, idealWidth: 200, maxWidth: 200)
                    .accessibilityLabel(title).accessibilityValue(valueText)
                Text(valueText).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }

    var models: some View {
        ModelsUpdatesView(service: service, updater: delegate.updater)
    }

}
