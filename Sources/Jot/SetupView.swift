import SwiftUI
import AppKit
import AVFoundation
import Combine
import JotCore

/// Where first-run setup stands, and the request to show it. Models, permissions and settings stay in SpeechService; this keeps only the progress, in SetupProgress.
@MainActor
final class SetupFlow: ObservableObject {
    @Published private(set) var progress = SetupProgress()
    /// The page on screen. Moving saves it, so setup resumes there after a relaunch.
    @Published private(set) var step = SetupStep.welcome
    /// Launch and the Set Up Jot command set this; the window switches to Setup and clears it, including when the window opens later.
    @Published var requested = false

    /// Before the service opens the store. An unfinished setup comes to the front, at the page it left, or earlier when a requirement is unmet now.
    func launch(readiness: SetupReadiness) {
        progress = SetupProgress.atLaunch(defaults: .standard, directory: JotPaths.directory)
        step = progress.resumeStep(readiness)
        requested = progress.offeredAtLaunch
    }

    /// The Set Up Jot command: where setup left off, or the summary once it is done.
    func open(readiness: SetupReadiness) {
        step = progress.resumeStep(readiness)
        requested = true
    }

    func go(to next: SetupStep) {
        step = next
        progress.step = next
        progress.save(to: .standard)
    }

    /// Launch stops opening setup; the Setup page and the menu command still do.
    func finishLater() {
        progress.status = .deferred
        progress.save(to: .standard)
    }

    func complete() {
        progress.status = .completed
        go(to: .summary)
    }
}

extension SpeechService {
    /// What setup's requirements read: models loaded now or by an earlier Resume, and both permissions.
    var setupReadiness: SetupReadiness {
        SetupReadiness(modelsReady: modelsLoaded || UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared),
                       microphoneAllowed: micPermission == .authorized, accessibilityAllowed: accessibilityGranted)
    }
}

/// How a row's state reads at a glance and to VoiceOver.
private enum SetupRowState {
    case done, needed, attention, optional
    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .needed: "circle"
        case .attention: "exclamationmark.triangle.fill"
        case .optional: "circle.dashed"
        }
    }
    var color: Color {
        switch self {
        case .done: .green
        case .attention: .orange
        case .needed, .optional: .secondary
        }
    }
    var spoken: String {
        switch self {
        case .done: "Done"
        case .needed: "Not done"
        case .attention: "Needs attention"
        case .optional: "Optional"
        }
    }
}

/// A requirement or state: its symbol, a name and a sentence, and its action on the right. The sentence wraps, so a narrow window keeps the action in view.
private struct SetupRow<Action: View>: View {
    let state: SetupRowState
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.symbol).font(.title3).foregroundStyle(state.color)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue(state.spoken)
            action().fixedSize()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// An optional feature's switch. While Apple Intelligence is unavailable it can still be turned off, as in General, but not on.
private struct SetupToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let available: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(available ? .primary : .secondary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .disabled(!available && !isOn)
                .accessibilityHint(detail)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// First-run setup, a page of the main window so it keeps the content pane beside the icon rail in a narrow window. Each page shows live
/// state and calls the actions the rest of Jot uses. Nothing here starts the microphone without a click on Resume or a held shortcut.
struct SetupView: View {
    @ObservedObject var service: SpeechService
    @ObservedObject var library: SessionLibrary
    @ObservedObject var flow: SetupFlow
    /// Leaves setup for Live, after Done or Finish later.
    let close: () -> Void
    @State private var downloadedBytes: Int64 = 0
    /// Dictations saved before the trial page opened, so a new one shows the trial worked.
    @State private var trialBaseline: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                page.frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        // Permissions change in System Settings; read them again as soon as the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refreshPermissions() }
        .onAppear { service.refreshPermissions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(SetupStep.allCases, id: \.self) { step in
                    Capsule().fill(step <= flow.step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)).frame(height: 4)
                }
            }
            .frame(maxWidth: 640).accessibilityHidden(true)
            Text("Step \(flow.step.rawValue + 1) of \(SetupStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
            Text(flow.step.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var page: some View {
        switch flow.step {
        case .welcome: welcome
        case .models: models
        case .microphone: microphone
        case .dictation: dictation
        case .intelligence: intelligence
        case .summary: summary
        }
    }

    /// Back, Finish later while setup is unfinished, and the way forward. It stays under the scrolling page, so a short window keeps it in view.
    private var footer: some View {
        HStack(spacing: 10) {
            if let previous = flow.step.previous {
                Button("Back") { flow.go(to: previous) }.modifier(GlassButton())
            }
            Spacer(minLength: 8)
            if flow.progress.status == .inProgress {
                Button("Finish Later") { flow.finishLater(); close() }.modifier(GlassButton())
                    .help("Setup stops opening at launch. Open it again from Setup in the sidebar or Jot → Set Up Jot….")
            }
            if let next = flow.step.next {
                Button(requirementMet ? "Continue" : "Skip for Now") { flow.go(to: next) }
                    .modifier(PrimaryGlassButton()).keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { flow.complete(); close() }
                    .modifier(PrimaryGlassButton()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// False on a page whose requirement is still unmet, so the forward button says the step is being skipped.
    private var requirementMet: Bool {
        switch flow.step {
        case .models: service.modelsLoaded || service.modelState == .preparing
        case .microphone: microphoneAllowed
        case .dictation: dictationReady
        default: true
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jot turns speech into text on this Mac. Recognition runs here, and audio is never uploaded. These steps take a few minutes; skip any of them and come back later.")
                .fixedSize(horizontal: false, vertical: true)
            point("waveform", "Listening", "Resume starts listening: Jot saves a searchable transcript of what the microphone hears in Sessions. Pause stops it. Nothing listens until you choose Resume.")
            point("keyboard", "Hold to dictate", "Hold \(service.shortcut.displayName) in a text field, speak and release. Jot types your words where the cursor is and never presses Return.")
            point("internaldrive", "Kept on this Mac", "Transcripts stay in ~/Library/Application Support/Jot. Session audio is kept only until the speaker pass finishes, then deleted.")
            point("arrow.down.circle", "One download", "Jot downloads about \(ModelCache.formatted(ModelCache.expectedBytes)) of speech models once, then works offline.")
            point("sparkles", "Optional Apple Intelligence", "Suggestions and cleanup use Apple's on-device model when macOS offers it. Everything else works without it.")
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Speech models

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The app is built for Apple silicon and macOS 14 or later only, so a running Jot is on a supported Mac.
            SetupRow(state: .done, title: "This Mac", detail: "macOS \(systemVersion) on Apple silicon, which Jot supports.") { EmptyView() }
            SetupRow(state: modelRowState, title: "Speech models", detail: modelDetail) { modelAction }
            if service.modelState == .preparing {
                ProgressView(value: Double(min(downloadedBytes, ModelCache.expectedBytes)), total: Double(ModelCache.expectedBytes)) {
                    Text(downloadProgress).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Text("Listening and dictation need the models. To download later, skip this step; Resume asks before it downloads.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: service.modelState == .preparing) { await followDownload() }
    }

    private var downloadProgress: String {
        downloadedBytes < ModelCache.expectedBytes
            ? "Downloaded \(ModelCache.formatted(downloadedBytes)) of about \(ModelCache.formatted(ModelCache.expectedBytes))"
            : "Downloaded. Loading the models…"
    }

    private var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    private var modelRowState: SetupRowState {
        switch service.modelState {
        case .ready: .done
        case .failed: .attention
        default: .needed
        }
    }

    private var modelDetail: String {
        switch service.modelState {
        case .ready:
            return service.cachedModelBytes > 0 ? "Downloaded and loaded: \(ModelCache.formatted(service.cachedModelBytes)) on this Mac." : "Downloaded and loaded."
        case .preparing: return "Downloading and loading. This can take several minutes, and you can continue meanwhile."
        case .failed: return "The download or loading stopped. Check the internet connection, then try again."
        case .unloading: return "Releasing the models…"
        case .notLoaded, .unloaded:
            return service.cachedModelBytes > 0
                ? "\(ModelCache.formatted(service.cachedModelBytes)) on this Mac. Loading downloads anything missing. The microphone stays off."
                : "About \(ModelCache.formatted(ModelCache.expectedBytes)) to download. The microphone stays off."
        }
    }

    @ViewBuilder private var modelAction: some View {
        switch service.modelState {
        case .ready, .unloading: EmptyView()
        case .preparing: ProgressView().controlSize(.small)
        case .failed:
            Button("Try Again") { service.prepareModelsOnly() }.modifier(PrimaryGlassButton())
                .disabled(service.isTransitioning || service.preparingUpdate)
        case .notLoaded, .unloaded:
            Button(service.cachedModelBytes > 0 ? "Load Models" : "Download") { service.prepareModelsOnly() }.modifier(PrimaryGlassButton())
                .disabled(service.isTransitioning || service.preparingUpdate)
                .accessibilityIdentifier("setup-download-models")
        }
    }

    /// FluidAudio reports no progress of its own, so this reads the model cache's size once a second, off the main thread, while models load.
    @MainActor private func followDownload() async {
        while service.modelState == .preparing, !Task.isCancelled {
            downloadedBytes = await Task.detached(priority: .utility) { ModelCache.bytesOnDisk() }.value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: Microphone

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jot listens only through the input chosen here, and never changes the Mac's default microphone.")
                .fixedSize(horizontal: false, vertical: true)
            SetupRow(state: microphoneState, title: "Microphone access", detail: microphoneDetail) { microphoneAction }
            MicrophoneRow(service: service, capture: service.capture)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            SetupRow(state: .optional, title: "Check the input level", detail: levelDetail) { levelAction }
        }
    }

    private var microphoneAllowed: Bool { service.micPermission == .authorized }

    private var microphoneState: SetupRowState {
        if microphoneAllowed { return .done }
        return service.micPermission == .notDetermined ? .needed : .attention
    }

    private var microphoneDetail: String {
        if microphoneAllowed { return "Allowed. Jot uses the microphone only while listening or while you hold the dictation shortcut." }
        if service.micPermission == .notDetermined { return "macOS asks once. Jot needs it to hear you." }
        return "Off for Jot. Switch Jot on in System Settings → Privacy & Security → Microphone, then come back."
    }

    @ViewBuilder private var microphoneAction: some View {
        if service.micPermission == .notDetermined {
            Button("Allow Microphone") { service.fixMicrophonePermission() }.modifier(PrimaryGlassButton())
        } else if !microphoneAllowed {
            Button("Open System Settings") { service.fixMicrophonePermission() }.modifier(GlassButton())
        }
    }

    private var levelDetail: String {
        if !microphoneAllowed { return "Allow microphone access first." }
        if !service.modelsLoaded { return "Needs the speech models, since listening transcribes what it hears." }
        if service.ambientEnabled { return "The microphone is on: speak and watch the level above. Jot saves what it hears in Sessions until you Pause." }
        return "Resume to see the level. Jot then listens and saves speech in Sessions until you Pause. Or skip this: holding the dictation shortcut turns the microphone on for the hold only."
    }

    @ViewBuilder private var levelAction: some View {
        if microphoneAllowed && !service.modelsLoaded {
            Button("Speech Models") { flow.go(to: .models) }.modifier(GlassButton())
        } else if microphoneAllowed {
            PauseResumeButton(service: service)
        }
    }

    // MARK: Dictation

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold \(service.shortcut.displayName) in a text field of another app, say a sentence and release. Jot types the words where the cursor is and never presses Return.")
                .fixedSize(horizontal: false, vertical: true)
            SetupRow(state: service.accessibilityGranted ? .done : .needed, title: "Accessibility access", detail: accessibilityDetail) {
                if !service.accessibilityGranted {
                    Button("Allow Accessibility") { service.fixAccessibilityPermission() }.modifier(PrimaryGlassButton())
                }
            }
            SetupRow(state: service.dictationEnabled ? .done : .needed, title: "Dictation shortcut", detail: shortcutDetail) { shortcutAction }
            SetupRow(state: trialSucceeded ? .done : .optional, title: "Try it", detail: trialDetail) { trialAction }
            VStack(alignment: .leading, spacing: 8) {
                tip("pause.circle", "Pause stops listening. Holding the shortcut still works while paused: the microphone turns on for the hold only.")
                tip("doc.text", "If Jot cannot insert, for example after focus changes, it keeps the words. Review saved dictation shows them to copy.")
                tip("globe", "If Fn opens emoji or another macOS feature, set the Fn/Globe key to Do Nothing in System Settings → Keyboard.")
            }
        }
        .onAppear { if trialBaseline == nil { trialBaseline = library.dictationCount } }
    }

    private var accessibilityDetail: String {
        service.accessibilityGranted
            ? "Allowed. Jot uses it to find the focused field and type into it."
            : "Needed to type into other apps. macOS asks, then shows Jot in Privacy & Security → Accessibility; switch it on and come back."
    }

    /// The shortcut tap runs only with the models loaded and both permissions granted.
    private var dictationReady: Bool { service.dictationEnabled && service.accessibilityGranted }

    private var shortcutDetail: String {
        if service.dictationEnabled { return "On. Hold \(service.shortcut.displayName) to dictate, whether Jot is listening or paused. Click the key to change it." }
        if !service.modelsLoaded { return "Needs the speech models first." }
        if !microphoneAllowed { return "Needs microphone access first." }
        if !service.accessibilityGranted { return "Needs Accessibility access first." }
        return "Off. Turn it on to dictate with \(service.shortcut.displayName)."
    }

    @ViewBuilder private var shortcutAction: some View {
        if service.dictationEnabled {
            ShortcutSettings(service: service)
        } else if !service.modelsLoaded {
            Button("Speech Models") { flow.go(to: .models) }.modifier(GlassButton())
        } else if !microphoneAllowed {
            Button("Microphone") { flow.go(to: .microphone) }.modifier(GlassButton())
        } else if service.accessibilityGranted {
            Button("Turn On") { Task { await service.enableDictation() } }.modifier(PrimaryGlassButton())
        }
    }

    private var trialSucceeded: Bool { trialBaseline.map { library.dictationCount > $0 } ?? false }

    private var trialDetail: String {
        if trialSucceeded { return "Jot saved your dictation. If the words did not appear in the field, Review saved dictation shows them to copy." }
        if !service.dictationEnabled { return "Turn on the dictation shortcut first." }
        return "Click into a text field in another app, such as a new TextEdit document, then hold \(service.shortcut.displayName), speak and release."
    }

    @ViewBuilder private var trialAction: some View {
        if trialSucceeded {
            ReviewSavedDictationButton(service: service).modifier(GlassButton())
        } else if service.dictationEnabled {
            Button("Open TextEdit") {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") { _ = NSWorkspace.shared.open(app) }
            }.modifier(GlassButton())
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Apple Intelligence

    private var intelligenceAvailable: Bool { service.cleanupAvailability == .available }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional. Dictation, listening, search and saved-dictation review work without Apple Intelligence. Jot never turns it on or accepts Apple's terms for you.")
                .fixedSize(horizontal: false, vertical: true)
            SetupRow(state: intelligenceAvailable ? .done : .optional, title: "Apple Intelligence",
                     detail: intelligenceAvailable ? "Available on this Mac. Each feature below is a separate choice." : service.cleanupAvailability.explanation) {
                if service.cleanupAvailability == .notEnabled || service.cleanupAvailability == .modelNotReady {
                    Button("Open System Settings") { openIntelligenceSettings() }.modifier(GlassButton())
                }
            }
            SetupToggle(title: "Suggestions",
                        detail: service.cleanupAvailability.suggestionBlocker ?? "Double-tap Fn in a text field for a draft: it continues text at the cursor, rewrites a selection, or replies in an empty chat box. Tab accepts; typing or Escape dismisses. Nothing is sent.",
                        isOn: $service.suggestionsEnabled, available: intelligenceAvailable)
            SetupToggle(title: "Clean up listening", detail: "Makes live speech and meetings more readable. The recognized text is kept when cleanup cannot run.",
                        isOn: $service.cleanUpTranscriptions, available: intelligenceAvailable)
            SetupToggle(title: "Clean up dictation", detail: "Cleans a dictation before inserting it. Off is faster.",
                        isOn: $service.cleanUpDictation, available: intelligenceAvailable)
            Text("Change these later in General.").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Apple Intelligence & Siri in System Settings. Turning it on, and Apple's terms, stay with the user.
    private func openIntelligenceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") else { return }
        _ = NSWorkspace.shared.open(url)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupRow(state: modelRowState, title: "Speech models", detail: service.modelsLoaded ? "Loaded." : "Not loaded. Listening and dictation need them.") { review(.models) }
            SetupRow(state: microphoneState, title: "Microphone", detail: microphoneAllowed ? "Allowed. Input: \(service.capture.inputName)." : "Not allowed yet.") { review(.microphone) }
            SetupRow(state: dictationReady ? .done : .needed, title: "Dictation",
                     detail: dictationReady ? "Hold \(service.shortcut.displayName) in a text field, speak and release." : shortcutDetail) { review(.dictation) }
            SetupRow(state: .optional, title: "Listening",
                     detail: service.ambientEnabled ? "On. Jot saves what it hears in Sessions; Pause stops it." : "Paused. Resume to listen and save speech in Sessions; Pause stops it again.") {
                if service.modelsLoaded { PauseResumeButton(service: service) }
            }
            SetupRow(state: .optional, title: "Apple Intelligence", detail: intelligenceSummary) { review(.intelligence) }
            Text("Transcripts stay in ~/Library/Application Support/Jot. To come back here, choose Setup in the sidebar or Jot → Set Up Jot….")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func review(_ step: SetupStep) -> some View {
        Button("Review") { flow.go(to: step) }.modifier(GlassButton()).accessibilityLabel("Review \(step.title)")
    }

    private var intelligenceSummary: String {
        guard intelligenceAvailable else { return service.cleanupAvailability.explanation }
        let features: [String?] = [service.suggestionsEnabled ? "suggestions" : nil,
                                   service.cleanUpTranscriptions ? "listening cleanup" : nil,
                                   service.cleanUpDictation ? "dictation cleanup" : nil]
        let on = features.compactMap { $0 }
        return on.isEmpty ? "Available, with every feature off." : "On: " + on.joined(separator: ", ") + "."
    }
}
