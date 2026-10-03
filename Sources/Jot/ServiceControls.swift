import SwiftUI
import AppKit
import JotCore

/// Every control row shares one grammar: a 20-point gutter for a symbol or status dot, a title with an optional caption, and the control on the right edge.
private struct ControlRow<Control: View>: View {
    var symbol: String? = nil
    var dot: Color? = nil
    let title: String
    var caption: String? = nil
    var secondary = false
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                else if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                else { Color.clear }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(secondary ? .callout : .body).foregroundStyle(secondary ? .secondary : .primary).lineLimit(1)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            control()
        }.frame(maxWidth: .infinity)
    }
}

struct ServiceControls: View {
    @ObservedObject var service: SpeechService
    var compact = false
    private var statusTitle: String {
        if service.preparingUpdate { return "Updating" }
        if service.switchingInput { return "Switching microphone" }
        if service.holdOnlyCapture { return "Dictating" }
        return service.isPaused ? "Paused" : (service.isTransitioning ? "Starting" : (service.ambientEnabled ? "Listening" : "Ready"))
    }
    private var statusCaption: String {
        if service.preparingUpdate { return "Saving captured speech…" }
        if service.switchingInput { return "Listening continues automatically" }
        if service.holdOnlyCapture { return "Microphone on for the hold" }
        if service.isPaused {
            if service.pauseRequested { return "Finishing…" }
            if service.isTransitioning { return "Releasing models…" }
            return service.modelsLoaded ? "Microphone off · models loaded" : "Models unloaded"
        }
        if service.modelState == .preparing { return "Loading models…" }
        return service.ambientEnabled ? "Saving speech locally" : "Starting microphone…"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlRow(dot: service.isPaused ? Color.secondary : .green, title: statusTitle, caption: statusCaption) {
                PauseResumeButton(service: service)
            }
            Divider()
            MeetingControls(service: service)
            Divider()
            MicrophoneRow(service: service, capture: service.capture)
            ControlRow(symbol: "keyboard", title: "Dictation") {
                Toggle("Dictation", isOn: Binding(get: { service.dictationRequested }, set: { enabled in
                    if enabled { Task { await service.enableDictation() } } else { service.disableDictation() }
                })).labelsHidden().toggleStyle(.switch)
            }.help("Hold \(service.shortcut.displayName) to dictate, while listening or paused. Double-tap Fn only requests suggestions when enabled.")
            ControlRow(title: "Hold to talk", secondary: true) { ShortcutSettings(service: service) }
            ControlRow(title: "Keep Mac awake", caption: "While listening", secondary: true) {
                Toggle("Keep Mac awake while listening", isOn: $service.keepMacAwakeWhileListening).labelsHidden().toggleStyle(.switch)
            }.help("Prevents idle sleep while listening. Closing the lid can still put the Mac to sleep; Jot resumes listening after wake if it was listening before sleep.")
            ReviewSavedDictationButton(service: service).modifier(GlassButton())
            if service.recoveryNotice.isEmpty && service.isPaused {
                Text("Resume to listen and save speech.").font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
            }
            ServiceGuidance(service: service)
        }
    }
}

/// The same first-run and recovery guidance stays available when navigation folds into an icon rail.
struct ServiceGuidance: View {
    @ObservedObject var service: SpeechService
    var showRecoveryAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !service.recoveryNotice.isEmpty {
                if showRecoveryAction { ReviewSavedDictationButton(service: service).modifier(GlassButton()) }
                Text(service.recoveryNotice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, showRecoveryAction ? 0 : 30)
                    .accessibilityIdentifier("dictation-recovery-notice")
            }
            if let pending = service.downloadPrompt {
                Divider()
                ModelDownloadPrompt(service: service, bytes: pending)
            }
            if service.permissionsMissing {
                Divider()
                PermissionBanner(service: service)
            }
        }
    }
}

/// Pause or Resume, shared by the sidebar's status row and the narrow window's rail.
struct PauseResumeButton: View {
    @ObservedObject var service: SpeechService
    var iconOnly = false
    private var resumes: Bool { service.isPaused || service.microphoneOff }
    var body: some View {
        let button = Button {
            if resumes { service.prepare() } else { service.pause() }
        } label: {
            Label(resumes ? "Resume" : "Pause", systemImage: resumes ? "play.fill" : "pause.fill")
        }
        Group {
            if iconOnly { button.labelStyle(.iconOnly) } else { button }
        }
        .modifier(PrimaryGlassButton())
        .disabled(service.preparingUpdate || (service.isPaused && service.isTransitioning))
        .help("Pause stops listening and finishes saving captured speech. The models stay loaded, so Resume is immediate.")
        .accessibilityIdentifier("service-pause-resume")
    }
}

/// Observes only the device list, so a device change redraws this row and not the whole card. Setup's microphone page shows it too.
struct MicrophoneRow: View {
    @ObservedObject var service: SpeechService
    @ObservedObject var capture: CaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlRow(symbol: "mic", title: "Microphone") {
                Picker("Microphone", selection: Binding(get: { capture.selectedInputUID }, set: { service.setInput(uid: $0) })) {
                    Text("System Default (\(capture.systemDefaultInputName))").tag("")
                    ForEach(capture.inputRows) { device in Text(device.name).tag(device.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                .disabled(!service.canChangeInput)
            }
            .help("Change input while listening. Jot saves captured speech and continues on the selected microphone.")
            if service.ambientEnabled {
                ProgressView(value: Double(capture.inputLevel), total: 8)
                    .accessibilityLabel("Microphone input level")
                    .accessibilityValue("\(capture.inputLevel) of 8")
                    .padding(.leading, 30)
            }
            Toggle("Switch silent microphones", isOn: $service.automaticMicrophone)
                .font(.caption).toggleStyle(.checkbox).padding(.leading, 30)
                .help("After ten seconds with no input signal, try other connected microphones. Keep one that receives sound, or return to the original if none does.")
            if capture.findingInput {
                Text("Checking connected microphones for sound…").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 30)
            } else if capture.inputIsSilent && service.ambientEnabled {
                Text("No input signal. A closed MacBook lid can disable its built-in microphone. Choose another input above.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 30)
            }
        }
    }
}

/// The menu's last line of the recording session. Observes the rows, so each saved row redraws this line and not the menu.
private struct LastSentence: View {
    @ObservedObject var library: SessionLibrary
    @ObservedObject var timeline: ListeningTimeline
    var body: some View {
        if let last = library.recent.first(where: { $0.sessionID == timeline.activeSessionID }) {
            Text(last.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .help("Last transcribed sentence")
        }
    }
}

/// One row to record a named meeting; ending it saves the transcript and shows the file.
private struct MeetingControls: View {
    @ObservedObject var service: SpeechService
    @State private var naming = false
    @State private var draft = ""
    @State private var working = false
    var body: some View {
        if let title = service.meetingTitle {
            ControlRow(dot: service.ambientEnabled ? .red : Color.secondary, title: title, caption: caption) {
                Button(working ? "Saving…" : "End") {
                    working = true
                    Task { await service.endMeeting(); working = false }
                }.modifier(PrimaryGlassButton()).disabled(working).accessibilityIdentifier("end-meeting")
            }
        } else if naming {
            VStack(alignment: .leading, spacing: 8) {
                ControlRow(symbol: "record.circle", title: "Meeting", caption: "Name it, then start") { EmptyView() }
                HStack(spacing: 8) {
                    TextField("Meeting name", text: $draft).textFieldStyle(.roundedBorder).onSubmit { start() }
                    Button("Start") { start() }.modifier(PrimaryGlassButton())
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    Button("Cancel") { naming = false; draft = "" }.modifier(GlassButton())
                }.padding(.leading, 30)
            }
        } else {
            ControlRow(symbol: "record.circle", title: "Meeting", caption: "Give a conversation a name") {
                Button("Start") { naming = true }.modifier(GlassButton()).accessibilityIdentifier("start-meeting")
                    .help("Ending it saves Markdown to Documents/Jot Sessions.")
            }
        }
    }
    /// An automatic pause keeps the meeting for Resume; the row must not claim to record until capture is back.
    private var caption: String { service.isPaused ? "Paused, resumes with Jot" : (service.ambientEnabled ? "Recording" : "Starting") }
    private func start() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        working = true
        Task { await service.startMeeting(title); working = false; naming = false; draft = "" }
    }
}

/// Asks before the first model download so the user chooses when to spend the bandwidth.
private struct ModelDownloadPrompt: View {
    @ObservedObject var service: SpeechService
    let bytes: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Download speech models?").font(.headline)
                InfoButton(title: "Model sizes", detail: "Sizes are approximate and depend on the published model revision.")
            }
            Text("Jot downloads \(ModelCache.formatted(bytes)) once, then transcribes and separates speakers on this Mac without sending audio anywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ModelCache.expected) { model in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).font(.callout)
                        Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ModelCache.formatted(model.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Not now") { service.downloadPrompt = nil }.modifier(GlassButton())
                Spacer()
                Button("Download") { service.prepare(confirmingDownload: true) }.modifier(PrimaryGlassButton())
                    .accessibilityIdentifier("confirm-model-download")
            }
        }
    }
}

/// Stays visible until every permission is granted; the one button does whatever macOS still allows.
private struct PermissionBanner: View {
    @ObservedObject var service: SpeechService
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(service.missingPermissionText).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Fix") { service.fixPermissions() }.modifier(PrimaryGlassButton())
                .accessibilityIdentifier("fix-permissions")
        }
    }
}

/// Observe resource samples only inside the meters, without rebuilding their parent.
struct ResourceReadoutView<Content: View>: View {
    @ObservedObject var readout: ResourceReadout
    @ViewBuilder var content: (ResourceSnapshot) -> Content

    var body: some View { content(readout.snapshot) }
}

struct MenuControls: View {
    @ObservedObject var service: SpeechService
    let delegate: JotDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                JotBrand(compact: true)
                Spacer()
                Button("Open", systemImage: "arrow.up.forward") {
                    delegate.openAction = { openWindow(id: "main") }
                    delegate.showWindow()
                }.modifier(GlassButton())
            }
            ServiceControls(service: service, compact: true)
                .padding(18).modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.04)))
            HStack {
                ResourceReadoutView(readout: service.resourceReadout) { resources in
                    Text(String(format: "CPU %.1f%% · %.0f MB", resources.processCPUPercent, resources.residentMiB))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if service.modelsLoaded && !service.isTransitioning {
                    Button("Unload Models") { service.unloadModels() }.buttonStyle(.plain)
                        .help("Frees the speech models' memory. Listening stops first; Resume loads them again.")
                }
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }
            if service.ambientEnabled { LastSentence(library: service.library, timeline: service.timeline) }
        }.padding(18).frame(width: 350)
            .modifier(GlassStage()).background(JotBackdrop()).tint(Color(nsColor: .controlAccentColor))
    }
}
