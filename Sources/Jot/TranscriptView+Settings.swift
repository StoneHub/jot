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

extension TranscriptView {
    var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !service.notice.isEmpty {
                    Text(service.notice).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                    GridRow { metric("Process CPU", String(format: "%.1f%%", service.resources.processCPUPercent)); metric("Memory", String(format: "%.0f MB", service.resources.residentMiB)) }
                    GridRow { metric("Memory footprint", String(format: "%.0f MB", service.resources.physicalFootprintMiB)); metric("Thermal state", service.resources.thermalState.capitalized) }
                    GridRow { metric("Queued audio", String(format: "%.1f s", service.queuedSeconds)); metric("Last inference", String(format: "%.2f s", service.lastInferenceSeconds)) }
                    GridRow { metric("Transcript lag", String(format: "%.2f s", service.lagSeconds)); metric("Dropped audio", String(format: "%.1f s", service.droppedSeconds)) }
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

    var tuning: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Suggestions", isOn: Binding(get: { service.suggestionsEnabled }, set: service.setSuggestionsEnabled))
                        .toggleStyle(.switch)
                    HStack {
                        Text("Additional shortcut (optional)")
                        Spacer()
                        ShortcutSettings(service: service, forSuggestions: true)
                    }
                    Text("Type or dictate rough notes in any text field, then double-tap Fn: Jot drafts finished text, and Tab replaces your notes (or just the selected part). In an empty chat box, double-tap Fn for a reply to the conversation shown above it. Typing or Escape dismisses. Nothing is sent. Works while listening is paused.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Use visible conversation", isOn: Binding(get: { service.suggestionScreenContext }, set: service.setSuggestionScreenContext))
                        .toggleStyle(.switch)
                    Text("Reads the text shown above the field in the same window when you ask for a suggestion. It stays on this Mac and is never saved.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Include the latest meeting", isOn: Binding(get: { service.suggestionMeetingContext }, set: service.setSuggestionMeetingContext))
                        .toggleStyle(.switch)
                    Text("Adds speech from the latest session in the last 30 minutes to every suggestion. When off, the card offers it with one click.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Experimental: review each draft. Suggestions can get facts or speaker roles wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recover dictation").font(.headline)
                    Text("With Suggestions off, focus a text field and double-tap \(service.shortcut.displayName) to retry an undelivered dictation. Otherwise, insert speech from the recent window below.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("Recent speech window")
                        Spacer()
                        Picker("Recent speech window", selection: $service.recoveryLookbackSeconds) {
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                            Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600)
                        }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                            .accessibilityIdentifier("recovery-lookback")
                    }
                    Text("Includes every voice Jot hears. A saved undelivered dictation takes priority, even when it is longer than this window. Inserts at the cursor or replaces selected text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Outline the text field while dictating", isOn: $service.highlightTargetField)
                        .toggleStyle(.switch)
                    Text("A pulsing accent border marks the field your words will go into, from when you hold the shortcut until the text is inserted.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Mute built-in speakers during dictation", isOn: $service.muteSpeakersDuringDictation)
                        .toggleStyle(.switch)
                    Text("Restores the previous mute state when you release your shortcut. Other audio outputs are unchanged. Media keeps playing silently.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep session audio until the speaker pass finishes", isOn: $service.keepAudioForSpeakerPass)
                        .toggleStyle(.switch)
                    Text("Audio is deleted right after the pass. Turn off to never write audio to disk.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("New session after quiet")
                        Spacer()
                        Picker("New session after quiet", selection: $service.newSessionAfterSilence) {
                            ForEach(SessionSplit.choices, id: \.self) { Text(SessionSplit.label($0)).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                    }
                    Text("Listening starts a new session when nothing is said for this long. A named meeting runs until you end it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Clean up live speech and meetings", isOn: $service.cleanUpTranscriptions)
                        .toggleStyle(.switch)
                        .disabled(service.cleanupAvailability != .available)
                    Text(service.cleanupAvailability.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Clean up dictation", isOn: $service.cleanUpDictation)
                        .toggleStyle(.switch)
                        .disabled(service.cleanupAvailability != .available)
                    Text("Adds an Apple Intelligence cleanup pass before inserting text. Leave off for faster dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Balanced") { service.tuning = .init() }
                    Button("Steadier speakers") { service.tuning = .steady }
                    Button("More detail") { service.tuning = .detailed }
                }.modifier(GlassButton())
                tuningSlider("Speaker confidence", value: $service.tuning.speakerConfidence, range: 0.45...0.9, step: 0.05,
                    valueText: String(format: "%.0f%%", service.tuning.speakerConfidence * 100),
                    detail: "Higher requires stronger evidence for a speaker label; more speech may remain unknown.")
                tuningSlider("Minimum speaker turn", value: $service.tuning.minimumSpeakerTurn, range: 0.2...2, step: 0.1,
                    valueText: String(format: "%.1f s", service.tuning.minimumSpeakerTurn),
                    detail: "Higher reduces speaker changes from brief hesitations. Short real replies may stay with the previous speaker.")
                tuningSlider("Pause between paragraphs", value: $service.tuning.paragraphPause, range: 0.3...2.5, step: 0.1,
                    valueText: String(format: "%.1f s", service.tuning.paragraphPause),
                    detail: "Longer pauses make fewer, longer rows. Nearby dictation rows from the same speaker are also grouped.")
                Toggle("Hide filler-only rows", isOn: $service.tuning.hideFillerRows).toggleStyle(.switch)
                Text("Hides rows containing only sounds such as um or uh. Original text is kept. Fillers inside sentences stay visible.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Speaker settings apply to new audio and to any session you Regroup that has no speaker pass. Paragraph grouping and filler visibility also update saved dictations.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Try the same short scene twice. Change one setting, then compare words, speaker changes, and paragraph breaks separately.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text(valueText).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
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
                Text("Updates are checked on demand. Downloaded models are kept until an update is explicitly installed.").font(.caption).foregroundStyle(.secondary)
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
