import SwiftUI
import AppKit
import JotCore

/// Top of the Models tab: the installed version, an on-demand release check, and the update itself.
private struct AppUpdateRow: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var service: SpeechService
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Jot \(JotVersion.current)").font(.headline)
                Spacer()
                if case .available(let release) = updater.state {
                    Link("Release notes", destination: release.pageURL)
                    Button("Update") { updater.install() }
                        .disabled(!service.canInstallUpdate).modifier(GlassButton())
                        .help(service.canInstallUpdate ? "Downloads the release and relaunches Jot." : "Pause capture before updating")
                } else {
                    Button(updater.state == .checking ? "Checking…" : "Check for updates") { updater.check() }
                        .disabled(updater.state == .checking || updater.state == .installing).modifier(GlassButton())
                }
            }
            switch updater.state {
            case .idle: EmptyView()
            case .checking: Text("Checking GitHub releases…").font(.callout).foregroundStyle(.secondary)
            case .upToDate(let version): Text("Jot \(version) is the latest release.").font(.callout).foregroundStyle(.secondary)
            case .available(let release):
                Text("Version \(release.version.description) available").font(.callout)
                if !release.firstNoteLine.isEmpty { Text(release.firstNoteLine).font(.caption).foregroundStyle(.secondary) }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading…").font(.caption).foregroundStyle(.secondary) }
            case .installing: Text("Verifying and installing…").font(.callout).foregroundStyle(.secondary)
            case .failed(let message): Text(message).font(.callout).foregroundStyle(.red)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A setting's explanation behind a small (i). Resting the pointer on it opens a popover; a click or Space keeps it open until clicked again, for keyboard and VoiceOver use.
private struct InfoButton: View {
    let title: String
    let detail: String
    @State private var showing = false
    @State private var pinned = false
    @State private var hover: Task<Void, Never>?
    var body: some View {
        Button { pinned.toggle(); showing = pinned } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(showing ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .accessibilityHint(detail)
        .onHover { inside in
            hover?.cancel()
            if inside {
                hover = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled { showing = true }
                }
            } else if !pinned { showing = false }
        }
        .onChange(of: showing) { _, shown in if !shown { pinned = false } }
        .onDisappear { hover?.cancel() }
        .popover(isPresented: $showing) {
            Text(detail).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// A titled card of setting rows; the caller places a RowDivider between rows.
private struct SettingsGroup<Rows: View>: View {
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
                        .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                }
                if let info { InfoButton(title: title, detail: info) }
            }.padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

/// A setting's name and (i) on the left and its control on the right. An indented row depends on the one above; a row that cannot change dims its name and disables its control, while its (i) still works.
private struct SettingRow<Control: View>: View {
    let title: String
    let info: String
    var indented = false
    var enabled = true
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(enabled ? .primary : .secondary)
            InfoButton(title: title, detail: info)
            Spacer(minLength: 12)
            control().disabled(!enabled)
        }
        .padding(.leading, indented ? 30 : 14).padding(.trailing, 14).padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

/// A switch row. An unavailable one is disabled and says so beside the switch.
private struct SettingToggle: View {
    let title: String
    let info: String
    @Binding var isOn: Bool
    var indented = false
    var enabled = true
    var unavailable = false
    var body: some View {
        SettingRow(title: title, info: info, indented: indented, enabled: enabled && !unavailable) {
            HStack(spacing: 8) {
                if unavailable { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

extension TranscriptView {
    var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !service.notice.isEmpty {
                    Text(service.notice).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ResourceReadoutView(readout: service.resourceReadout) { resources in
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                        GridRow { metric("Process CPU", String(format: "%.1f%%", resources.processCPUPercent)); metric("Memory", String(format: "%.0f MB", resources.residentMiB)) }
                        GridRow { metric("Memory footprint", String(format: "%.0f MB", resources.physicalFootprintMiB)); metric("Thermal state", resources.thermalState.capitalized) }
                        GridRow { metric("Queued audio", String(format: "%.1f s", service.queuedSeconds)); metric("Last inference", String(format: "%.2f s", service.lastInferenceSeconds)) }
                        GridRow { metric("Transcript lag", String(format: "%.2f s", service.lagSeconds)); metric("Dropped audio", String(format: "%.1f s", service.droppedSeconds)) }
                    }
                }
                Divider()
                Text("Capture events").font(.headline)
                ForEach(service.events) { event in
                    HStack(alignment: .top) {
                        Text(event.timestamp, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(event.detail).font(.callout)
                    }
                }
                if service.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dictationSettings
                suggestionSettings
                listeningSettings
                speakerSettings
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
            SettingToggle(title: "Clean up with Apple Intelligence", info: cleanupInfo("Runs an Apple Intelligence cleanup pass before inserting text. Off is faster."),
                          isOn: $service.cleanUpDictation, unavailable: service.cleanupAvailability != .available)
            RowDivider()
            SettingRow(title: "Recovery window", info: recoveryInfo) {
                Picker("Recovery window", selection: $service.recoveryLookbackSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                }.labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityIdentifier("recovery-lookback")
            }
        }
    }

    private var suggestionSettings: some View {
        SettingsGroup(title: "Suggestions", symbol: "sparkles", info: "Experimental. Review each draft: suggestions can get facts or speaker roles wrong.", beta: true) {
            SettingToggle(title: "Suggestions", info: "Write rough notes in any text field, then double-tap Fn. Jot drafts finished text, and Tab replaces your notes or the selected part. In an empty chat box, it drafts a reply to the conversation above. Typing or Escape dismisses. Nothing is sent. Works while listening is paused.",
                          isOn: Binding(get: { service.suggestionsEnabled }, set: service.setSuggestionsEnabled))
            RowDivider()
            SettingRow(title: "Extra shortcut", info: "Optional. Requests a suggestion, like double-tapping Fn.", indented: true, enabled: service.suggestionsEnabled) {
                ShortcutSettings(service: service, forSuggestions: true)
            }
            RowDivider()
            SettingToggle(title: "Read visible conversation", info: "When you ask for a suggestion, reads the text shown above the field in the same window. It stays on this Mac and is never saved.",
                          isOn: Binding(get: { service.suggestionScreenContext }, set: service.setSuggestionScreenContext),
                          indented: true, enabled: service.suggestionsEnabled)
            RowDivider()
            SettingToggle(title: "Include latest meeting", info: "Adds speech from the latest session in the past 30 minutes to every suggestion. When off, the card offers it with one click.",
                          isOn: Binding(get: { service.suggestionMeetingContext }, set: service.setSuggestionMeetingContext),
                          indented: true, enabled: service.suggestionsEnabled)
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
            SettingToggle(title: "Clean up with Apple Intelligence", info: cleanupInfo("Uses Apple Intelligence on this Mac to make live speech and meetings more readable."),
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

    /// The cleanup explanation while Apple Intelligence can run, otherwise why it cannot.
    private func cleanupInfo(_ available: String) -> String {
        service.cleanupAvailability == .available ? available : service.cleanupAvailability.explanation
    }

    private var recoveryInfo: String {
        let base = "Double-tap \(service.shortcut.displayName) in a text field to insert speech Jot did not deliver. A saved dictation comes first, even when it is longer than this window. Otherwise Jot inserts what it heard in this window, every voice included, at the cursor or over the selection."
        return service.suggestionsEnabled && service.shortcut.keyCode == nil ? base + " While Suggestions is on, double-tap Fn asks for a suggestion instead." : base
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
                Picker("Preset", selection: Binding<TuningPreset?>(get: { TuningPreset.matching(service.tuning) }, set: { if let preset = $0 { service.tuning = preset.tuning } })) {
                    ForEach(TuningPreset.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }

    private func tuningSlider(_ title: String, info: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        SettingRow(title: title, info: info) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 200)
                    .accessibilityLabel(title).accessibilityValue(valueText)
                Text(valueText).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }

    var models: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AppUpdateRow(updater: delegate.updater, service: service)
                HStack {
                    Text(service.modelState.rawValue.capitalized).foregroundStyle(.secondary)
                    if service.cachedModelBytes > 0 {
                        Text("· \(ModelCache.formatted(service.cachedModelBytes)) cached").foregroundStyle(.secondary)
                    }
                    InfoButton(title: "Model updates", detail: "Updates are checked only when you ask. Downloaded models are kept until you install an update.")
                    Spacer()
                    Button(service.checkingModels ? "Checking…" : "Check updates") { service.checkModelUpdates() }
                        .disabled(service.checkingModels).modifier(GlassButton())
                }
                ForEach(service.modelUpdates) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            Link("Releases", destination: model.releasesURL)
                        }
                        Text(model.summary).font(.callout).foregroundStyle(.secondary)
                        if let checked = model.checkedAt { Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                Link("FluidAudio releases", destination: URL(string: "https://github.com/FluidInference/FluidAudio/releases")!)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit()) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}
