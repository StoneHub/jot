import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import FluidAudio

/// The raw values are stored in the capture_events table and shown in History.
enum CaptureEventKind: String {
    case started, paused, stopped, sleep
    case deviceChange = "device_change", inputStalled = "input_stalled"
    case audioGap = "audio_gap", audioDiscarded = "audio_discarded", processingError = "processing_error"
    case speakerPass = "speaker_pass", sessionSplit = "session_split", databaseReplaced = "database_replaced"
}

/// Injectable seams for the agent-runnable recovery harness. Production still uses
/// the real local pipeline and accessibility delivery; no socket or product UI is
/// involved in synthetic verification.
struct SpeechServiceDependencies {
    var infer: @MainActor (SpeechPipeline, AudioJob, TranscriptionTuning) async throws -> SpeechOutput
    var deliver: @MainActor (DictationInput, String) async throws -> DictationInput.DeliveryResult
    var now: @MainActor () -> Date
    var cleanup: @MainActor (TranscriptCleanup, [String], Duration) async -> CleanupResult = { cleaner, texts, timeout in
        await cleaner.cleanWithOutcome(texts, timeout: timeout)
    }
    var makeMicrophone: @MainActor () -> MicrophoneSource = { MicrophoneCapture() }
    var microphoneRetry = MicrophoneStartRetry()
    var prepareModels: @MainActor (SpeechPipeline) async throws -> Void = { try await $0.prepare() }
    var unloadModels: @MainActor (SpeechPipeline) async -> Void = { await $0.unload() }
    var microphoneAuthorization: @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophoneAccess: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }

    static let live = SpeechServiceDependencies(
        infer: { pipeline, job, tuning in try await pipeline.infer(job, tuning: tuning) },
        deliver: { input, text in try await input.insert(text) },
        now: Date.init)
}

@MainActor
final class SpeechService: ObservableObject {
    let dependencies: SpeechServiceDependencies
    let capture: CaptureController
    lazy var library = SessionLibrary(service: self)
    lazy var speakers = SpeakerRecognizer(pass: pipeline.speakerPass, service: self)
    lazy var dictation = DictationCoordinator(service: self)
    /// What agents told Jot lately, for suggestions. In memory only; see AgentContext.
    let agentContext = AgentContext()
    lazy var suggestions = SuggestionCoordinator(input: input, store: { [weak self] in self?.library.store },
        history: { [weak self] in self?.suggestionHistory },
        agentContext: agentContext,
        allowed: { [weak self] in self?.canRequestSuggestion == true },
        readsScreen: { [weak self] in self?.suggestionScreenContext == true },
        window: { [weak self] in TimeInterval((self?.suggestionWindowMinutes ?? 10) * 60) },
        matchesHeardSpeech: { [weak self] in self?.suggestionHeardMatches == true },
        notice: { [weak self] in self?.notice = $0 })
    lazy var timeline = ListeningTimeline(service: self)
    lazy var cleanup = LiveCleanup(service: self)
    lazy var transcriber = Transcriber(service: self)

    init(dependencies: SpeechServiceDependencies = .live) {
        self.dependencies = dependencies
        capture = CaptureController(microphone: dependencies.makeMicrophone(), retry: dependencies.microphoneRetry)
        capture.onNotice = { [weak self] in self?.notice = $0 }
    }
    /// Where every setting below is saved. Each property reads its value at launch and saves it when it changes; `jot settings` writes the same store and calls applySettings().
    let settings = JotSettings.standard
    @Published var lifecycle = ServiceLifecycle()
    @Published var fnRequested = UserDefaults.standard.bool(forKey: JotDefaultsKey.fnRequested)
    @Published private(set) var shortcut = ShortcutPreferences().load()
    @Published private(set) var suggestionShortcut = SuggestionShortcutPreferences().load()
    @Published private(set) var suggestionsEnabled = JotSettings.standard.bool(JotDefaultsKey.suggestionsEnabled)
    /// Read the text shown above the field, such as a chat, for a request. Local and never stored.
    @Published private(set) var suggestionScreenContext = JotSettings.standard.bool(JotDefaultsKey.suggestionScreenContext)
    func setSuggestionScreenContext(_ enabled: Bool) {
        suggestionScreenContext = enabled
        settings.set(JotDefaultsKey.suggestionScreenContext, enabled)
        suggestions.dismiss(action: .settingsChanged)
    }
    /// A selection rewrite can restore quoted words from matching speech within the context window.
    @Published private(set) var suggestionHeardMatches = JotSettings.standard.bool(JotDefaultsKey.suggestionHeardMatches)
    func setSuggestionHeardMatches(_ enabled: Bool) {
        suggestionHeardMatches = enabled
        settings.set(JotDefaultsKey.suggestionHeardMatches, enabled)
        suggestions.dismiss(action: .settingsChanged)
    }
    /// How far back a suggestion may read: speech Jot heard and messages agents sent it, in minutes.
    @Published private(set) var suggestionWindowMinutes = JotSettings.standard.int(JotDefaultsKey.suggestionWindowMinutes)
    func setSuggestionWindowMinutes(_ minutes: Int) {
        settings.set(JotDefaultsKey.suggestionWindowMinutes, minutes)
        suggestionWindowMinutes = settings.int(JotDefaultsKey.suggestionWindowMinutes)
        suggestions.dismiss(action: .settingsChanged)
    }
    var canRequestSuggestion: Bool { suggestionBlocker == nil }
    /// Why a suggestion cannot be requested right now, in the words the card shows.
    var suggestionBlocker: String? {
        if !suggestionsEnabled { return "Suggestions are off in General." }
        if dictation.isActive || dictation.isPending { return "No suggestion while a dictation is in progress." }
        if diagnosticActive { return "No suggestion while diagnostics run." }
        if preparing { return "No suggestion while Jot is loading models." }
        if cleanup.isRunning { return "Jot is cleaning up speech; double-tap again in a moment." }
        return nil
    }
    func setSuggestionsEnabled(_ enabled: Bool) {
        suggestionsEnabled = enabled
        settings.set(JotDefaultsKey.suggestionsEnabled, enabled)
        if enabled && !DictationInput.accessibilityGranted { input.requestAccessibility() }
        if !enabled { suggestions.dismiss(action: .settingsChanged) }
        updateSuggestionMonitoring()
    }
    func setSuggestionShortcut(_ value: DictationShortcut) throws {
        guard canChangeShortcut else { throw JotError.message("Finish dictation before changing a shortcut.") }
        try SuggestionShortcutPreferences().save(value, dictation: shortcut)
        suggestionShortcut = value; input.suggestionShortcut = value
        if suggestionsEnabled && !DictationInput.accessibilityGranted { input.requestAccessibility() }
        updateSuggestionMonitoring()
    }
    private func updateSuggestionMonitoring() {
        suggestions.dismiss(action: .settingsChanged)
        input.dictationEnabled = fnEnabled
        if fnEnabled || (suggestionsEnabled && DictationInput.accessibilityGranted) {
            _ = input.enable()
        } else { input.disable() }
        input.fnSuggestionsEnabled = suggestionsEnabled
    }
    var canChangeShortcut: Bool { !dictation.isActive && !dictation.isPending }
    var canChangeInput: Bool { !capture.running && !dictation.isPending && !diagnosticActive }
    /// Replacing the app must not interrupt capture, a pending dictation, inference, model setup, cleanup, or a session's relabel.
    var canInstallUpdate: Bool { canChangeInput && transcriber.processing == nil && !preparing && !cleanup.isRunning && !library.isRelabeling }
    @Published var highlightTargetField = JotSettings.standard.bool(JotDefaultsKey.highlightTargetField) {
        didSet {
            settings.set(JotDefaultsKey.highlightTargetField, highlightTargetField)
            if !highlightTargetField { dictation.hideHighlight() }
        }
    }
    @Published var muteSpeakersDuringDictation = JotSettings.standard.bool(JotDefaultsKey.muteSpeakersDuringDictation) {
        didSet {
            settings.set(JotDefaultsKey.muteSpeakersDuringDictation, muteSpeakersDuringDictation)
            if !muteSpeakersDuringDictation { dictation.endSpeakerMute() }
        }
    }
    @Published var keepMacAwakeWhileListening = JotSettings.standard.bool(JotDefaultsKey.keepMacAwakeWhileListening) {
        didSet {
            settings.set(JotDefaultsKey.keepMacAwakeWhileListening, keepMacAwakeWhileListening)
            updateKeepAwakeAssertion()
        }
    }
    /// Minutes of quiet that end an ambient session; 0 keeps one session until capture stops. A named meeting never splits.
    @Published var newSessionAfterSilence = JotSettings.standard.int(JotDefaultsKey.newSessionAfterSilence) {
        didSet { settings.set(JotDefaultsKey.newSessionAfterSilence, newSessionAfterSilence) }
    }
    /// Off means no audio reaches disk and no speaker pass runs. Switching off mid-session deletes that session's file; switching on waits for the next session, since a file that starts mid-session would misplace every segment.
    @Published var keepAudioForSpeakerPass = JotSettings.standard.bool(JotDefaultsKey.keepAudioForSpeakerPass) {
        didSet {
            settings.set(JotDefaultsKey.keepAudioForSpeakerPass, keepAudioForSpeakerPass)
            if !keepAudioForSpeakerPass { timeline.discardSessionAudio() }
        }
    }

    @Published var cleanUpTranscriptions = JotSettings.standard.bool(JotDefaultsKey.cleanUpTranscriptions) {
        didSet { settings.set(JotDefaultsKey.cleanUpTranscriptions, cleanUpTranscriptions) }
    }
    @Published var cleanUpDictation = JotSettings.standard.bool(JotDefaultsKey.cleanUpDictation) {
        didSet { settings.set(JotDefaultsKey.cleanUpDictation, cleanUpDictation) }
    }
    @Published var recoveryLookbackSeconds = JotSettings.standard.int(JotDefaultsKey.recoveryLookbackSeconds) {
        didSet {
            let bounded = min(600, max(15, recoveryLookbackSeconds))
            if bounded != recoveryLookbackSeconds { recoveryLookbackSeconds = bounded; return }
            settings.set(JotDefaultsKey.recoveryLookbackSeconds, bounded)
        }
    }
    @Published var recoveryNotice = ""
    @Published private(set) var cleanupAvailability = TranscriptCleanup.availability

    /// Brings each setting in line with the store after `jot settings` changed it, with the side effects a change on screen has.
    func applySettings() {
        let key = JotDefaultsKey.self
        if suggestionsEnabled != settings.bool(key.suggestionsEnabled) { setSuggestionsEnabled(settings.bool(key.suggestionsEnabled)) }
        if suggestionScreenContext != settings.bool(key.suggestionScreenContext) { setSuggestionScreenContext(settings.bool(key.suggestionScreenContext)) }
        if suggestionHeardMatches != settings.bool(key.suggestionHeardMatches) { setSuggestionHeardMatches(settings.bool(key.suggestionHeardMatches)) }
        if suggestionWindowMinutes != settings.int(key.suggestionWindowMinutes) { setSuggestionWindowMinutes(settings.int(key.suggestionWindowMinutes)) }
        if highlightTargetField != settings.bool(key.highlightTargetField) { highlightTargetField = settings.bool(key.highlightTargetField) }
        if muteSpeakersDuringDictation != settings.bool(key.muteSpeakersDuringDictation) { muteSpeakersDuringDictation = settings.bool(key.muteSpeakersDuringDictation) }
        if keepMacAwakeWhileListening != settings.bool(key.keepMacAwakeWhileListening) { keepMacAwakeWhileListening = settings.bool(key.keepMacAwakeWhileListening) }
        if newSessionAfterSilence != settings.int(key.newSessionAfterSilence) { newSessionAfterSilence = settings.int(key.newSessionAfterSilence) }
        if keepAudioForSpeakerPass != settings.bool(key.keepAudioForSpeakerPass) { keepAudioForSpeakerPass = settings.bool(key.keepAudioForSpeakerPass) }
        if cleanUpTranscriptions != settings.bool(key.cleanUpTranscriptions) { cleanUpTranscriptions = settings.bool(key.cleanUpTranscriptions) }
        if cleanUpDictation != settings.bool(key.cleanUpDictation) { cleanUpDictation = settings.bool(key.cleanUpDictation) }
        if recoveryLookbackSeconds != settings.int(key.recoveryLookbackSeconds) { recoveryLookbackSeconds = settings.int(key.recoveryLookbackSeconds) }
        let saved = settings.tuning
        if tuning != saved { tuning = saved }
    }

    func setShortcutRecording(_ active: Bool) { suggestions.dismiss(action: .settingsChanged); input.isRecordingShortcut = active }

    func setShortcut(_ value: DictationShortcut) throws {
        guard canChangeShortcut else { throw JotError.message("Finish dictation before changing its shortcut.") }
        if let suggestionShortcut, value.keyCode == suggestionShortcut.keyCode && value.modifiers == suggestionShortcut.modifiers {
            throw JotError.message("Choose a key different from the suggestion shortcut.")
        }
        try ShortcutPreferences().save(value)
        shortcut = value
        input.shortcut = value
    }

    @Published var ambientRequested = false
    @Published private(set) var ambientEnabled = false
    /// Where listening stands, read from the lifecycle, the microphone and a held dictation. `jot status` reports its mode and model state.
    var listeningState: ListeningState {
        ListeningState(phase: lifecycle.phase, generation: lifecycle.generation, microphoneOn: ambientEnabled, dictationActive: dictation.isActive)
    }
    var mode: String { listeningState.mode }
    var modelState: ListeningState.Models { listeningState.models }
    @Published var notice = ""
    @Published var modelUpdates = ModelUpdate.defaults
    @Published var checkingModels = false
    @Published var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibilityGranted = DictationInput.accessibilityGranted
    @Published private(set) var cachedModelBytes = ModelCache.bytesOnDisk()
    /// Set when a resume would download models that are not cached yet. The view asks before any download starts.
    @Published var downloadPrompt: Int64?
    /// Title of the meeting being recorded; nil when ambient is off or was started without a name.
    @Published private(set) var meetingTitle: String?
    @Published var tuning = JotSettings.standard.tuning {
        didSet {
            settings.setTuning(tuning.bounded)
            library.refreshHistory()
            // Live groups by the paragraph pause alone, so a slider drag of any other setting leaves it as it is.
            if tuning.bounded.paragraphPause != oldValue.bounded.paragraphPause {
                library.reloadLive()
            }
        }
    }
    @Published private(set) var vocabulary = PersonalVocabulary()
    @Published private(set) var vocabularyLoadError: String?
    private let vocabularyPreferences = VocabularyPreferences()

    func saveVocabularyEntry(_ entry: VocabularyEntry) throws {
        guard vocabularyLoadError == nil else { throw VocabularyError.invalid("Saved vocabulary could not be loaded. Resolve the storage error before editing.") }
        var updated = vocabulary
        try updated.save(entry)
        try vocabularyPreferences.save(updated)
        vocabulary = updated
    }

    func removeVocabularyEntry(_ id: UUID) throws {
        guard vocabularyLoadError == nil else { throw VocabularyError.invalid("Saved vocabulary could not be loaded. Resolve the storage error before editing.") }
        var updated = vocabulary
        updated.remove(id)
        try vocabularyPreferences.save(updated)
        vocabulary = updated
    }

    var modelCheck: Task<Void, Never>?
    let resourceReadout = ResourceReadout()
    var resources: ResourceSnapshot { resourceReadout.snapshot }
    #if DEBUG
    var diagnostics = PerformanceDiagnostics(build: .debug)
    #else
    var diagnostics = PerformanceDiagnostics(build: .release)
    #endif
    private let diagnosticsBegan = ProcessInfo.processInfo.systemUptime

    /// Records CPU and memory for `jot diagnostics`. The window's readout comes from the tick, with a sampler of its own.
    func samplePerformance() {
        let sample = sampler.sample()
        guard sample.valid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: sample.physicalFootprintMiB,
            residentMiB: sample.residentMiB, cpuPercent: sample.processCPUPercent,
            droppedAudioSeconds: droppedSeconds, bufferedAudioSeconds: AudioClock.seconds(samples: capture.bufferedSampleCount + timeline.bufferedSampleCount) + transcriber.inFlightAudioSeconds,
            queuedAudioSeconds: transcriber.queuedAudioSeconds, loadedHistoryRows: library.history.count,
            modelsReady: modelState == .ready, ambientEnabled: ambientEnabled, dictationActive: dictation.isActive,
            inferenceRunning: transcriber.processing != nil))
    }

    func markPerformance(_ kind: PerformanceEventKind) {
        samplePerformance()
        diagnostics.mark(kind, at: ProcessInfo.processInfo.systemUptime - diagnosticsBegan)
    }

    /// Records a finished job, stamped with the time it finished.
    func recordPerformance(_ job: PerformanceJob) {
        var job = job
        job.elapsedSeconds = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.record(job)
    }

    @Published var fnEnabled = false
    @Published var droppedSeconds = 0.0
    /// Not published: it changes on every audio drain, and each published assignment tells the window to redraw.
    var lastAudioAt: Date?
    /// Resume is loading models or restarting the microphone.
    var preparing: Bool { preparation != nil }
    let pipeline = SpeechPipeline()
    private let sampler = ResourceSampler()
    /// A sampler measures CPU since its previous sample, and `sampler` also samples when a recognition finishes. Sharing it would leave each recognition's CPU out of the next readout, so the readout has its own, sampled only at launch and by the tick.
    private let readoutSampler = ResourceSampler()
    private let keepAwake = KeepAwakeAssertion()
    private var server: LocalServiceServer?
    var suggestionHistory: SuggestionHistory?
    private var timer: Timer?
    /// A `jot` file diagnostic is running. Published because the microphone picker and Update read it through canChangeInput.
    @Published var diagnosticActive = false
    /// Screens read `preparing` from this, so a change redraws them the way the stored flag's mode update did.
    private var preparation: Task<Void, Never>? { willSet { objectWillChange.send() } }
    private var pausing: Task<Void, Never>?
    private var sleepResume = SleepResumePolicy()
    var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    private(set) var pauseRequested = false
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.dictation.begin() }, onStop: { [weak self] in self?.dictation.end() })
        result.shortcut = shortcut
        result.dictationEnabled = false
        result.suggestionShortcut = suggestionShortcut
        result.suggestionAllowed = { [weak self] in
            guard let self else { return false }
            return self.canRequestSuggestion && self.suggestions.keyboardAllowsSuggestions
        }
        result.onSuggestionRequest = { [weak self] in self?.suggestions.request() }
        result.onSuggestionRefused = { [weak self] in
            guard let self else { return }
            self.suggestions.refuse(self.suggestionBlocker ?? "Suggestions are not available on this keyboard layout.")
        }
        result.onSuggestionAccept = { [weak self] in self?.suggestions.accept() }
        result.onSuggestionDismiss = { [weak self] action in self?.suggestions.dismiss(action: action) }
        result.startBlocker = { [weak self] in
            guard let self else { return "Jot is shutting down." }
            return DictationReadiness.blocker(phase: self.lifecycle.phase, modelsReady: self.modelState == .ready,
                ambientEnabled: self.ambientEnabled, pauseRequested: self.pauseRequested, dictationPending: self.dictation.isPending,
                dictationActive: self.dictation.isActive, diagnosticActive: self.diagnosticActive)
        }
        result.onError = { [weak self] error in
            self?.notice = error.localizedDescription
            if self?.dictation.isActive == true {
                self?.recoveryNotice = "Speech is still being saved. Use the recovery gesture in a text field to insert it."
            }
        }
        result.onRecover = { [weak self] in self?.dictation.recoverRecent() }
        result.onDiscardTap = { [weak self] in self?.dictation.cancelTap() }
        return result
    }()

    func launch() {
        markPerformance(.launch)
        resourceReadout.snapshot = readoutSampler.sample()
        capture.watchDevices()
        do { vocabulary = try vocabularyPreferences.load() }
        catch { vocabularyLoadError = "Could not load vocabulary. Saved entries were preserved. " + error.localizedDescription }
        do {
            let opened = try TranscriptStore()
            library.store = opened
            // Diagnostics are best effort; a telemetry schema failure must not stop capture or history access.
            suggestionHistory = try? SuggestionHistory(sharing: opened)
            if opened.replacedDatabase {
                recordEvent(.databaseReplaced, "Saved history was in a format this version does not read; it was deleted and an empty database created.")
                notice = "Saved history was in a format this version does not read, so it was replaced with an empty history."
            }
            // Converts interrupted holds with the vocabulary loaded above.
            try dictation.finalizeInterruptedAttempts()
            speakers.speakerStore = try SpeakerPassStore(sharing: opened)
            speakers.peopleStore = try PeopleStore(sharing: opened); speakers.refreshPeople()
            let service = LocalServiceServer { [weak self] data in
                guard let self else { return Data("{\"ok\":false,\"error\":\"Service unavailable\"}".utf8) }
                return await self.handle(data)
            }
            try service.start(); server = service
            library.refreshRecent(); library.refreshSessions()
            if let attempt = try library.store?.latestRecoverableDictationAttempt() {
                recoveryNotice = attempt.hasGap
                    ? "Partial dictation was saved. Review it in Sessions; recovery can insert the recognized portion."
                    : "Saved dictation is ready to retry in the current text field."
            }
            for stale in SessionAudioFile.discardStale(except: timeline.sessionID) { recordEvent(.audioDiscarded, "Session audio left by an earlier run was deleted.", session: stale) }
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.modelUpdateChecks),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            if UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared), !UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused) {
                ambientRequested = true
                prepare()
            }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
        promptForPermissionsAtLaunch()
        _ = suggestions
        updateSuggestionMonitoring()
        scheduleTimer()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleepResume.willSleep(ambientRunning: self.ambientEnabled)
                self.recordEvent(.sleep, "Capture paused because the Mac is sleeping."); self.pause(automatic: true); self.notice = "Paused for sleep."
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleepResume.didWake()
                self.resumeAfterSleepIfReady()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ambientEnabled || self.dictation.isActive else { return }
                if self.capture.shouldIgnoreConfigurationChange() { return }
                self.recordEvent(.deviceChange, "Audio input configuration changed."); self.pause(automatic: true); self.notice = "Audio input changed. Resume when ready."
            }
        })
    }

    /// A Pause still saving speech counts as paused and changing, though models stay loaded until it finishes.
    var isPaused: Bool { pauseRequested || listeningState.isPaused }
    var isTransitioning: Bool { pauseRequested || listeningState.isChanging }
    var keepAwakeActive: Bool { keepAwake.isActive }

    private func resumeAfterSleepIfReady() {
        guard sleepResume.takeResume(phase: lifecycle.phase) else { return }
        guard ambientRequested else { return }
        capture.refreshInputDevices()
        prepare()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = lifecycle.phase == .ready ? 0.2 : 5.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = interval / 5
        // An open menu or a live window resize takes the run loop out of its default mode; common modes keep the audio draining then.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Resume. The first resume downloads models, so it asks before spending bandwidth.
    func prepare(confirmingDownload: Bool = false) {
        guard !pauseRequested else {
            notice = "Pause is still saving captured speech. Resume when it finishes."
            return
        }
        guard !diagnosticActive else {
            notice = "Wait for the file diagnostic to finish before resuming listening."
            return
        }
        sleepResume.cancel()
        ambientRequested = true
        cachedModelBytes = ModelCache.bytesOnDisk()
        if cachedModelBytes == 0 && !confirmingDownload {
            downloadPrompt = ModelCache.expectedBytes
            return
        }
        downloadPrompt = nil
        guard let token = lifecycle.beginStart() else {
            if microphoneOff && preparation == nil { restartMicrophone() }
            return
        }
        UserDefaults.standard.set(false, forKey: JotDefaultsKey.servicePaused)
        markPerformance(.resume); markPerformance(.modelLoadStarted)
        notice = "Loading models…"
        preparation = Task {
            do {
                try await dependencies.prepareModels(pipeline)
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                markPerformance(.modelsReady)
                UserDefaults.standard.set(true, forKey: JotDefaultsKey.modelsPrepared)
                cachedModelBytes = ModelCache.bytesOnDisk()
                if fnRequested { await enableFn() }
                try await activateAmbient(); try continueMeeting()
                if lifecycle.acceptsWork(token) { notice = "" }
            } catch {
                if lifecycle.finishStart(token, succeeded: false) {
                    notice = error.localizedDescription
                    await dependencies.unloadModels(pipeline)
                } else if lifecycle.acceptsWork(token) { notice = error.localizedDescription }
            }
            preparation = nil; scheduleTimer()
        }
    }

    /// Models are loaded but the microphone never started, so Resume has nothing to reload and only the capture needs another try.
    var microphoneOff: Bool { listeningState == .ready && !pauseRequested }

    private func restartMicrophone() {
        preparation = Task {
            do { try await activateAmbient(); try continueMeeting() }
            catch { notice = error.localizedDescription }
            preparation = nil; scheduleTimer()
        }
    }

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

    /// A CLI or MCP resume is already an explicit request, so it downloads and reports the size instead of prompting.
    @discardableResult
    func prepareFromCommand() -> Int64 {
        let pending = ModelCache.bytesOnDisk() == 0 ? ModelCache.expectedBytes : 0
        prepare(confirmingDownload: true)
        return pending
    }

    /// Assigns only a change, since the tick calls this every second.
    func refreshPermissions() {
        let microphone = dependencies.microphoneAuthorization()
        if micPermission != microphone { micPermission = microphone }
        let accessibility = DictationInput.accessibilityGranted
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
    }

    var permissionsMissing: Bool { micPermission != .authorized || !accessibilityGranted }

    /// Sentence for the persistent banner, naming exactly what is still off.
    var missingPermissionText: String {
        var names: [String] = []
        if micPermission != .authorized { names.append("Microphone") }
        if !accessibilityGranted { names.append("Accessibility") }
        return names.joined(separator: " and ") + " access is off."
    }

    /// Startup asks once for whatever is missing. macOS shows its own dialogs, each with an Open System Settings button.
    private func promptForPermissionsAtLaunch() {
        Task {
            if micPermission == .notDetermined { _ = await requestMic() }
            if !DictationInput.accessibilityGranted { input.requestAccessibility() }
            refreshPermissions()
        }
    }

    /// The persistent button. Asks again where macOS still allows it, otherwise opens the exact settings pane.
    func fixPermissions() {
        if micPermission == .notDetermined { Task { _ = await requestMic() }; return }
        if micPermission != .authorized { openSettings("Privacy_Microphone"); return }
        input.requestAccessibility()
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func enableFn() async {
        fnRequested = true; UserDefaults.standard.set(true, forKey: JotDefaultsKey.fnRequested)
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token) else { return }
        guard await requestMic(), lifecycle.acceptsWork(token), fnRequested else { return }
        if !DictationInput.accessibilityGranted { input.requestAccessibility() }
        fnEnabled = input.enable()
        input.dictationEnabled = fnEnabled
        if !fnEnabled { notice = "Enable Accessibility access in System Settings, then switch dictation on again." }
    }

    func disableFn() {
        fnRequested = false; UserDefaults.standard.set(false, forKey: JotDefaultsKey.fnRequested)
        if dictation.isActive { dictation.end() }
        suggestions.dismiss(action: .settingsChanged)
        input.disable(); fnEnabled = false
        updateSuggestionMonitoring()
    }

    // MARK: Work that spans the owned objects

    func setInput(uid: String) {
        guard canChangeInput else { return }
        do { try capture.setInput(uid: uid); notice = "" }
        catch { notice = error.localizedDescription }
    }

    /// The session being recorded belongs to Live until capture stops.
    func canDeleteSession(_ id: String) -> Bool { !(id == timeline.activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        try library.deleteSession(id)
    }

    func regroupSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        try await library.regroupSession(id) { try speakers.segments(sessionID: id) }
        speakers.didRegroup(id)
    }

    func deleteHistoryCard(_ item: Transcript) throws {
        try library.deleteHistoryCard(item, discard: dictation.discard(ids:))
    }

    func clearHistory() throws {
        try library.clearHistory(discardAttempt: dictation.discardForHistoryReset)
    }

    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]? = nil) {
        // The name is saved before the voice is remembered, so Live shows it even when remembering the voice fails.
        defer { library.reloadLive() }
        do { try speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: voice) }
        catch { notice = error.localizedDescription }
    }

    /// The session's last audio block is recognized and its cleanup has landed, so its rows will not change under a relabel.
    func sessionIsSettled(_ id: String) -> Bool { transcriber.isDone(session: id) && !cleanup.isCleaning(session: id) }

    /// Models loaded, microphone on, no pause under way.
    var canHoldDictation: Bool { listeningState.modelsLoaded && ambientEnabled && !pauseRequested }

    /// Closes the audio chunk in progress so a held range starts or ends on an exact timeline boundary.
    func closeChunk() { drainAudio(); timeline.flushAmbient(final: true) }

    // MARK: Sessions and meetings

    /// A meeting is ambient capture with a name, and an export when it ends.
    func startMeeting(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { notice = "Give the meeting a name first."; return }
        do {
            try await startAmbient()
            guard ambientEnabled else { throw JotError.message("Ambient capture did not start.") }
            meetingTitle = trimmed
            try library.store?.setTitle(sessionID: timeline.sessionID, title: trimmed)
            library.refreshSessions()
        } catch { meetingTitle = nil; notice = error.localizedDescription }
    }

    /// Renames the running meeting: the name goes on its session now and on any continuation after an automatic pause.
    func renameMeeting(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meetingTitle != nil, !trimmed.isEmpty, let id = timeline.activeSessionID else { return }
        meetingTitle = trimmed; library.renameSession(id, title: trimmed)
    }

    /// Names any session from the socket. Naming the running meeting's session renames the meeting too, so the Live chip and a continuation after an automatic pause use the new name.
    func setSessionTitle(_ id: String, title: String) throws {
        try library.store?.setTitle(sessionID: id, title: title); library.refreshSessions()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle != nil, id == timeline.activeSessionID, !trimmed.isEmpty { meetingTitle = trimmed }
    }

    /// A meeting kept through an automatic pause records on into a new session under the same name. The earlier part stays in Sessions, and TranscriptExport.write adds " (2)" to a duplicate file name.
    private func continueMeeting() throws {
        guard let meetingTitle, ambientEnabled else { return }
        try library.store?.setTitle(sessionID: timeline.sessionID, title: meetingTitle); library.refreshSessions()
    }

    /// Closes and exports the named session while continuous listening immediately
    /// continues in a fresh untitled session.
    @discardableResult
    func endMeeting() async -> URL? {
        guard !pauseRequested else {
            notice = "Wait for Pause to finish before exporting the meeting."
            return nil
        }
        guard !dictation.isActive, !dictation.isPending else {
            notice = "Finish the held dictation before ending the meeting."
            return nil
        }
        library.clearLastExport()
        let id = timeline.sessionID
        let generation = lifecycle.generation
        if ambientEnabled { drainAudio(); timeline.flushAmbient(final: true) }
        let throughOffset = timeline.ambientOffset
        timeline.endSessionAudio(runPass: true)
        meetingTitle = nil
        if ambientEnabled {
            timeline.beginSession(at: dependencies.now())
            recordEvent(.started, "Listening continued in a fresh session after meeting export.")
            transcriber.kick()
        }
        if lifecycle.acceptsWork(generation) {
            await transcriber.waitUntilProcessed(sessionID: id, through: throughOffset)
            if !lifecycle.acceptsWork(generation) {
                notice = "Meeting export interrupted. Saved transcripts remain in Sessions; no file was exported."
                return nil
            }
        }
        library.refreshSessions()
        // A meeting with nothing transcribed ends quietly; there is no file to show.
        guard (try? library.store?.session(id: id).isEmpty) == false else { return nil }
        do {
            let url = try library.exportSession(id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch { notice = error.localizedDescription; return nil }
    }

    private func activateAmbient() async throws {
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token), !diagnosticActive, !pauseRequested else { throw JotError.message("Resume the service before listening.") }
        guard await requestMic() else { throw JotError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), ambientRequested, !pauseRequested else { return }
        guard !ambientEnabled else { return }
        if !capture.running { lastAudioAt = dependencies.now() }
        guard try await capture.startRetrying(shouldContinue: { lifecycle.acceptsWork(token) && ambientRequested && !pauseRequested }) else { return }
        timeline.beginSession(at: dependencies.now())
        ambientEnabled = true; updateKeepAwakeAssertion()
        recordEvent(.started, "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        ambientRequested = true
        if lifecycle.phase == .paused || lifecycle.phase == .failed { prepare() }
        if let preparation { await preparation.value }
        guard lifecycle.phase == .ready else { throw JotError.message("The service is not ready. Wait for Pause to finish, then Resume.") }
        try await activateAmbient()
    }

    /// Stop the microphone immediately, save already captured chunks, then release
    /// models. Automatic pauses keep listening intent and a running meeting for Resume.
    func pause(automatic: Bool = false) {
        if !automatic { sleepResume.cancel() }
        guard !pauseRequested, lifecycle.phase != .paused, lifecycle.phase != .pausing else { return }
        suggestions.dismiss(action: .serviceStopped)
        pauseRequested = true
        markPerformance(.pause)
        UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        capture.stop()
        drainAudio()
        if ambientEnabled { timeline.flushAmbient(final: true) }
        updateKeepAwakeAssertion()
        if ambientEnabled { recordEvent(.paused, "Service paused.") }
        timeline.endSessionAudio(runPass: automatic)
        let outcome = PauseOutcome(automatic: automatic, ambientRequested: ambientRequested, meetingTitle: meetingTitle)
        ambientRequested = outcome.ambientRequested; meetingTitle = outcome.meetingTitle
        input.disable(); fnEnabled = false
        updateSuggestionMonitoring()
        if dictation.isActive { dictation.end() }
        let loadingTask = preparation, fileTask = diagnostic
        loadingTask?.cancel(); fileTask?.cancel()
        notice = transcriber.isIdle ? "Releasing models…" : "Saving captured speech before Pause…"
        pausing = Task {
            await loadingTask?.value
            _ = try? await fileTask?.value
            while !transcriber.isIdle {
                transcriber.kick()
                try? await Task.sleep(for: .milliseconds(20))
            }
            await dictation.waitForRecovery()
            guard let token = lifecycle.beginPause() else {
                pauseRequested = false; pausing = nil; return
            }
            ambientEnabled = false; transcriber.queuedSeconds = 0
            // Optional text-only cleanup may finish after capture/models stop.
            // Original recognition is already durable; no microphone is retained.
            notice = "Releasing models…"; scheduleTimer()
            await dependencies.unloadModels(pipeline)
            if lifecycle.finishPause(token) {
                preparation = nil
                notice = outcome.endedMeeting ? "Meeting stopped. Its transcript is in Sessions." : ""
                markPerformance(.modelsUnloaded); scheduleTimer()
            }
            pauseRequested = false; pausing = nil
            resumeAfterSleepIfReady()
        }
    }

    private func tick() {
        if lifecycle.phase == .ready { drainAudio() }
        tickCount += 1
        if dependencies.now().timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = dependencies.now(); refreshPermissions()
            resourceReadout.snapshot = readoutSampler.sample()
            // A published assignment tells the window to redraw even when the value is the same, so only changes are assigned.
            let availability = TranscriptCleanup.availability
            if cleanupAvailability != availability { cleanupAvailability = availability }
            transcriber.queuedSeconds = transcriber.queuedAudioSeconds
            if !pauseRequested, ambientEnabled || dictation.isActive, let lastAudioAt, dependencies.now().timeIntervalSince(lastAudioAt) > 4 {
                recordEvent(.inputStalled, "No microphone samples for more than four seconds."); pause(automatic: true); notice = "Microphone stopped delivering audio. Resume to reconnect; a capture gap occurred."
            }
            if !pauseRequested, ambientEnabled, !dictation.isActive, !dictation.isPending,
               SessionSplit.shouldStart(silenceMinutes: newSessionAfterSilence,
                silenceSeconds: dependencies.now().timeIntervalSince(timeline.lastAmbientRowAt ?? timeline.sessionStarted),
                isMeeting: meetingTitle != nil, workPending: !transcriber.isIdle) { timeline.rotateSession() }
        }
        transcriber.kick()
    }

    func drainAudio() {
        let packet = capture.drain()
        timeline.ingestAudio(samples: packet.samples, dropped: packet.dropped, lastAudio: packet.lastAudio, rms: packet.rms)
    }

    /// Integration/performance seam: the same ingestion and scheduling path used by
    /// microphone drains, with inference and delivery supplied through dependencies.
    func ingestRecoveryVerification(samples: [Float], rms: Float = 0.01, at date: Date = Date()) {
        timeline.ingestAudio(samples: samples, dropped: 0, lastAudio: date, rms: rms)
        transcriber.kick()
    }

    func beginRecoveryVerification(store: TranscriptStore, startedAt: Date = Date()) {
        if let token = lifecycle.beginStart() { _ = lifecycle.finishStart(token, succeeded: true) }
        library.store = store
        ambientRequested = true; ambientEnabled = true
        timeline.beginSession(at: startedAt, withAudio: false)
    }

    func flushRecoveryVerification() {
        timeline.flushAmbient(final: true)
        transcriber.kick()
    }

    /// Runs one timer tick on the injected clock, so the harness reaches the quiet split and the stalled-microphone pause without starting the timer.
    func tickRecoveryVerification() { tick() }

    /// The harness waits for Resume, or a microphone restart, to settle.
    func waitForPreparation() async {
        if let preparation { await preparation.value }
    }

    func waitForRecoveryVerification() async {
        while !transcriber.isIdle || dictation.isBusy || cleanup.isRunning {
            transcriber.kick()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Counts and state only; transcript and field contents never enter diagnostics.
    var recoveryDiagnostics: [String: Any] {
        [
            "lookbackSeconds": recoveryLookbackSeconds,
            "attemptState": dictation.currentAttempt?.state.rawValue ?? "none",
            "attemptPending": dictation.isActive || dictation.isPending,
            "pendingAudioJobs": transcriber.jobs.count + (transcriber.processing == nil ? 0 : 1),
            "recoveryRunning": dictation.recoveryRunning,
            "cleanupPending": cleanup.pendingCount,
            "cleanupBufferedRows": cleanup.bufferedRowCount,
            "cleanupRequested": cleanup.cleanupRequestedCount,
            "cleanupCompleted": cleanup.cleanupCompletedCount,
            "cleanupApplied": cleanup.cleanupAppliedCount,
            "cleanupBypassed": cleanup.cleanupBypassedCount,
            "cleanupOutcomes": cleanup.cleanupOutcomeCounts
        ]
    }

    func recordEvent(_ kind: CaptureEventKind, _ detail: String, duration: Double? = nil, session: String? = nil) {
        let marker: PerformanceEventKind?
        switch kind {
        case .started: marker = .ambientStarted
        case .sleep: marker = .sleep
        case .deviceChange: marker = .deviceChange
        case .audioGap: marker = .audioGap
        case .processingError: marker = .processingFailed
        default: marker = nil
        }
        if let marker { markPerformance(marker) }
        do { try library.store?.appendEvent(CaptureEvent(sessionID: session ?? timeline.sessionID, kind: kind.rawValue, detail: detail, durationSeconds: duration)) }
        catch { notice = "Could not save capture event: \(error.localizedDescription)"; return }
        library.refreshEvents()
    }

    func checkModelUpdates() {
        guard !checkingModels else { return }
        checkingModels = true
        let current = modelUpdates
        modelCheck = Task {
            let results = await withTaskGroup(of: (Int, ModelUpdate).self) { group in
                for (index, model) in current.enumerated() { group.addTask { (index, await model.check()) } }
                var rows: [(Int, ModelUpdate)] = []
                for await row in group { rows.append(row) }
                return rows.sorted { $0.0 < $1.0 }.map(\.1)
            }
            modelUpdates = results
            if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: JotDefaultsKey.modelUpdateChecks) }
            checkingModels = false; modelCheck = nil
        }
    }

    func shutdown() {
        cleanup.shutdown()
        if ambientEnabled { recordEvent(.stopped, "Application quit; capture ended.") }
        modelCheck?.cancel(); preparation?.cancel(); transcriber.cancel(); diagnostic?.cancel(); pausing?.cancel()
        suggestions.dismiss(action: .serviceStopped)
        timer?.invalidate(); dictation.releaseFieldEffects(); input.disable(); capture.stop(); updateKeepAwakeAssertion(); server?.stop()
        capture.stopWatching()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    private func updateKeepAwakeAssertion() {
        keepAwake.setActive(keepMacAwakeWhileListening && ambientEnabled && capture.running)
    }
}
