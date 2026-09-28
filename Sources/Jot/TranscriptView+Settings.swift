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
                    Button("Update") { updater.install(service: service) }
                        .modifier(GlassButton())
                        .help("Downloads the release, saves captured speech, and relaunches Jot. Listening resumes automatically.")
                } else {
                    Button(updater.state == .checking ? "Checking…" : "Check for updates") { updater.check() }
                        .disabled(updater.isBusy).modifier(GlassButton())
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
            case .finishing: Text("Saving captured speech before relaunching…").font(.callout).foregroundStyle(.secondary)
            case .installing: Text("Verifying and installing…").font(.callout).foregroundStyle(.secondary)
            case .failed(let message): Text(message).font(.callout).foregroundStyle(.red)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A setting's explanation behind a small (i). Resting the pointer on it opens a popover; a click or Space keeps it open until clicked again, for keyboard and VoiceOver use.
struct InfoButton: View {
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

/// A setting's name and (i) on the left and its control on the right, or the control under the name when the row is too narrow for both. An indented row depends on the one above; a row that cannot change dims its name and disables its control, while its (i) still works.
private struct SettingRow<Control: View>: View {
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
private struct SettingToggle: View {
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
                        GridRow { metric("Queued audio", String(format: "%.1f s", service.transcriber.queuedSeconds)); metric("Last inference", String(format: "%.2f s", service.transcriber.lastInferenceSeconds)) }
                        GridRow { metric("Transcript lag", String(format: "%.2f s", service.transcriber.lagSeconds)); metric("Dropped audio", String(format: "%.1f s", service.droppedSeconds)) }
                    }
                }
                Divider()
                Text("Capture events").font(.headline)
                ForEach(library.events) { event in
                    HStack(alignment: .top) {
                        Text(event.timestamp, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(event.detail).font(.callout)
                    }
                }
                if library.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dictationSettings
                suggestionSettings
                recoverySettings
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
        }
    }

    private var suggestionSettings: some View {
        SettingsGroup(title: "Suggestions", symbol: "sparkles", info: "Experimental. Review each draft: suggestions can get facts or speaker roles wrong.", beta: true) {
            Text(service.cleanupAvailability.suggestionBlocker ?? "Optional Apple Intelligence drafts. Double-tap Fn to request; Tab accepts. Turning suggestions off leaves dictation unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
            SettingToggle(title: "Suggestions", info: "Select rough notes in a text field, then double-tap Fn to rewrite them. Without a selection, Jot continues at the cursor. In an empty chat box, it drafts a reply. Typing or Escape dismisses. Nothing is sent. Works while listening is paused. When off, double-Fn does not insert anything.",
                          isOn: $service.suggestionsEnabled, unavailable: service.cleanupAvailability != .available)
            RowDivider()
            SettingRow(title: "Extra shortcut", info: "Optional. Requests a suggestion, like double-tapping Fn.", indented: true, enabled: service.suggestionsEnabled && service.cleanupAvailability == .available) {
                ShortcutSettings(service: service, forSuggestions: true)
            }
            RowDivider()
            SettingToggle(title: "Read visible conversation", info: "When you ask for a suggestion, reads the text shown above the field in the same window. It stays on this Mac and is never saved.",
                          isOn: $service.suggestionScreenContext,
                          indented: true, enabled: service.suggestionsEnabled && service.cleanupAvailability == .available)
            RowDivider()
            SettingToggle(title: "Include window image", info: "Optional. When you ask for a suggestion, also gives the on-device model one image of the window around the field: the part above the field, in its column. It can show messages, an error or a chart that the text misses. It stays in memory for that request and is never saved. Needs Screen Recording permission, asked for when you turn this on, and macOS 27 with a model that takes images.",
                          isOn: $service.suggestionWindowImage,
                          indented: true, enabled: service.suggestionsEnabled && service.cleanupAvailability == .available,
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
                          indented: true, enabled: service.suggestionsEnabled && service.cleanupAvailability == .available)
            RowDivider()
            SettingRow(title: "Context window", info: "How far back a suggestion may read: speech Jot heard, with the speaker when known, and messages agents sent with `jot context add`. Older speech stays in Sessions; older agent messages are forgotten.",
                       indented: true, enabled: service.suggestionsEnabled && service.cleanupAvailability == .available) {
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
