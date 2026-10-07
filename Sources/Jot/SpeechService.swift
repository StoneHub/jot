import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import FluidAudio

@MainActor
final class SpeechService: ObservableObject {
    let dependencies: SpeechServiceDependencies
    let capture: CaptureController
    let storeExecutor = StoreExecutor()
    lazy var library: SessionLibrary = SessionLibrary(owner: self, settings: settings, executor: storeExecutor,
        setNotice: { [unowned self] in notice = $0 }, relabelsWillChange: { [unowned self] in objectWillChange.send() },
        isSessionSettled: { [weak self] in self?.sessionIsSettled($0) ?? true },
        isApplyingPass: { [weak self] in self?.speakers.isApplyingPass($0) ?? false })
    lazy var speakers: SpeakerRecognizer = SpeakerRecognizer(pass: pipeline.speakerPass, owner: self, library: library, settings: settings,
        recordEvent: { [unowned self] in recordEvent($0, $1, duration: $2, session: $3) }, setNotice: { [unowned self] in notice = $0 })
    lazy var dictation: DictationCoordinator = DictationCoordinator(owner: self, timeline: timeline, library: library,
        cleanup: cleanup, transcriber: transcriber, input: input, settings: settings,
        deliver: dependencies.deliver, now: dependencies.now,
        currentVocabulary: { [unowned self] in vocabulary }, shortcut: { [unowned self] in shortcut },
        canHold: { [unowned self] in canHoldDictation }, closeChunk: { [unowned self] in closeChunk() },
        markPerformance: { [unowned self] in markPerformance($0) }, recordPerformance: { [unowned self] in recordPerformance($0) },
        setNotice: { [unowned self] in notice = $0 }, setRecoveryNotice: { [unowned self] in recoveryNotice = $0 },
        stateWillChange: { [unowned self] in objectWillChange.send() }, stateChanged: { [unowned self] in refreshShortcutEligibility() })
    /// What agents told Jot lately, for suggestions. In memory only; see AgentContext.
    let agentContext = AgentContext()
    lazy var suggestions: SuggestionCoordinator = SuggestionCoordinator(input: input, store: { [weak self] in self?.library.store },
        history: { [weak self] in self?.suggestionHistory },
        agentContext: agentContext,
        allowed: { [weak self] in self?.canRequestSuggestion == true },
        readsScreen: { [weak self] in self?.suggestionScreenContext == true },
        includesWindowImage: { [weak self] in self?.suggestionWindowImage == true },
        window: { [weak self] in TimeInterval((self?.suggestionWindowMinutes ?? 10) * 60) },
        matchesHeardSpeech: { [weak self] in self?.suggestionHeardMatches == true },
        userVoice: { [weak self] in self?.speakers.userVoice },
        notice: { [weak self] in self?.notice = $0 })
    lazy var timeline: ListeningTimeline = ListeningTimeline(settings: settings, library: library, speakers: speakers,
        transcriber: transcriber, now: dependencies.now,
        isListening: { [unowned self] in ambientEnabled }, isDictating: { [unowned self] in dictation.isActive },
        receivedAudio: { [unowned self] in lastAudioAt = $0 }, droppedAudio: { [unowned self] in droppedSeconds += $0 },
        recordEvent: { [unowned self] in recordEvent($0, $1, duration: $2, session: nil) },
        setNotice: { [unowned self] in notice = $0 }, markDictationGap: { [weak self] in self?.dictation.markGap($0) })
    lazy var cleanup: LiveCleanup = LiveCleanup(owner: self, library: library, settings: settings,
        clean: dependencies.cleanup, availability: dependencies.intelligenceAvailability,
        activityChanged: { [unowned self] in refreshShortcutEligibility() },
        workerFinished: { [unowned self] in if canInstallUpdate { objectWillChange.send() } })
    lazy var transcriber: Transcriber = Transcriber(owner: self, library: library, cleanup: cleanup, pipeline: pipeline, settings: settings,
        infer: dependencies.infer, now: dependencies.now, lifecycle: { [unowned self] in lifecycle },
        recordFailure: { [unowned self] in recordEvent(.processingError, $0, session: $1) },
        setNotice: { [unowned self] in notice = $0 }, recordPerformance: { [unowned self] in recordPerformance($0) },
        recognitionEnded: { [unowned self] in
            if !ambientEnabled && canInstallUpdate { objectWillChange.send() }
            samplePerformance()
        },
        recordedRows: { [weak self] job in
            guard let self else { return }
            if job.sessionID == self.timeline.sessionID { self.timeline.lastAmbientRowAt = self.dependencies.now() }
        }, recognitionCompleted: { [weak self] in self?.dictation.updateAttemptText(for: $0) },
        recognitionFailed: { [weak self] in self?.dictation.noteRecognitionFailure(for: $0) })

    init(dependencies: SpeechServiceDependencies = .live) {
        self.dependencies = dependencies
        cleanupAvailability = dependencies.intelligenceAvailability()
        capture = CaptureController(microphone: dependencies.makeMicrophone(), retry: dependencies.microphoneRetry,
            availableDevices: dependencies.availableInputs, defaultDeviceUID: dependencies.defaultInputUID)
        capture.onNotice = { [weak self] in self?.notice = $0 }
    }
    /// A fresh listening start opens Live; input changes preserve the current tab.
    @Published private(set) var livePresentationRevision = 0
    @Published private(set) var switchingInput = false { didSet { refreshShortcutEligibility() } }
    @Published private(set) var preparingUpdate = false { didSet { refreshShortcutEligibility() } }
    private var inputChange: Task<Void, Never>?
    private var resumeAfterUpdate = false
    private var updateRecovery: Task<Void, Never>?

    // MARK: Settings

    /// The one store. Nothing here copies a value out of it: each property below reads it, and each setter writes it and
    /// then calls `settingChanged`, which applies the side effect the setting has and redraws the screens. `jot settings`
    /// writes the same store over the socket and calls `settingChanged` too, so a change applies at once either way.
    let settings = JotSettings.standard

    /// After the store took a new value for `key`, from a screen or from `jot settings`: the side effect that setting has,
    /// then a redraw. The store already holds the value, so a setting with no side effect only redraws.
    func settingChanged(_ key: String) {
        objectWillChange.send()
        switch key {
        case JotDefaultsKey.automaticMicrophone: capture.resetInputSearch()
        case JotDefaultsKey.suggestionsEnabled:
            if suggestionsEnabled && !DictationInput.accessibilityGranted { input.requestAccessibility() }
            updateSuggestionMonitoring()
        case JotDefaultsKey.suggestionScreenContext, JotDefaultsKey.suggestionHeardMatches, JotDefaultsKey.suggestionWindowMinutes:
            suggestions.dismiss(action: .settingsChanged)
        case JotDefaultsKey.suggestionWindowImage:
            // The one place Screen Recording is asked for: turning the image on, never a request.
            if suggestionWindowImage && !WindowImageCapture.permitted { WindowImageCapture.requestPermission() }
            suggestions.dismiss(action: .settingsChanged)
        case JotDefaultsKey.highlightTargetField:
            if !highlightTargetField { dictation.hideHighlight() }
        case JotDefaultsKey.muteSpeakersDuringDictation:
            if !muteSpeakersDuringDictation { dictation.endSpeakerMute() }
        case JotDefaultsKey.keepMacAwakeWhileListening:
            updateKeepAwakeAssertion()
        case JotDefaultsKey.keepAudioForSpeakerPass:
            if !keepAudioForSpeakerPass { timeline.discardSessionAudio() }
        case JotSettings.speakerConfidence, JotSettings.minimumSpeakerTurn, JotSettings.hideFillerRows:
            library.refreshHistory()
        case JotSettings.paragraphPause:
            // Live groups by the paragraph pause alone, so a change to any other tuning value leaves it as it is.
            library.refreshHistory(); library.reloadLive()
        default: break
        }
    }

    private func save(_ key: String, _ value: Bool) { settings.set(key, value); settingChanged(key) }
    private func save(_ key: String, _ value: Int) { settings.set(key, value); settingChanged(key) }

    var automaticMicrophone: Bool {
        get { settings.bool(JotDefaultsKey.automaticMicrophone) }
        set { save(JotDefaultsKey.automaticMicrophone, newValue) }
    }

    var suggestionsEnabled: Bool {
        get { settings.bool(JotDefaultsKey.suggestionsEnabled) }
        set { save(JotDefaultsKey.suggestionsEnabled, newValue) }
    }
    /// Read the text shown above the field, such as a chat, for a request. Local and never stored.
    var suggestionScreenContext: Bool {
        get { settings.bool(JotDefaultsKey.suggestionScreenContext) }
        set { save(JotDefaultsKey.suggestionScreenContext, newValue) }
    }
    /// Add one image of the window around the field to a request. Local, in memory for that request, never stored.
    var suggestionWindowImage: Bool {
        get { settings.bool(JotDefaultsKey.suggestionWindowImage) }
        set { save(JotDefaultsKey.suggestionWindowImage, newValue) }
    }
    /// The model is ready and takes images: macOS 27 or later with a model that has vision.
    var windowImageSupported: Bool { AppleFMGeneration.acceptsImages }
    func openScreenRecordingSettings() { openSettings("Privacy_ScreenCapture") }
    /// A selection rewrite can restore quoted words from matching speech within the context window.
    var suggestionHeardMatches: Bool {
        get { settings.bool(JotDefaultsKey.suggestionHeardMatches) }
        set { save(JotDefaultsKey.suggestionHeardMatches, newValue) }
    }
    /// How far back a suggestion may read: speech Jot heard and messages agents sent it, in minutes.
    var suggestionWindowMinutes: Int {
        get { settings.int(JotDefaultsKey.suggestionWindowMinutes) }
        set { save(JotDefaultsKey.suggestionWindowMinutes, newValue) }
    }
    var highlightTargetField: Bool {
        get { settings.bool(JotDefaultsKey.highlightTargetField) }
        set { save(JotDefaultsKey.highlightTargetField, newValue) }
    }
    var muteSpeakersDuringDictation: Bool {
        get { settings.bool(JotDefaultsKey.muteSpeakersDuringDictation) }
        set { save(JotDefaultsKey.muteSpeakersDuringDictation, newValue) }
    }
    var keepMacAwakeWhileListening: Bool {
        get { settings.bool(JotDefaultsKey.keepMacAwakeWhileListening) }
        set { save(JotDefaultsKey.keepMacAwakeWhileListening, newValue) }
    }
    /// Minutes of quiet that end an ambient session; 0 keeps one session until capture stops. A named meeting never splits.
    var newSessionAfterSilence: Int {
        get { settings.int(JotDefaultsKey.newSessionAfterSilence) }
        set { save(JotDefaultsKey.newSessionAfterSilence, newValue) }
    }
    /// Off means no audio reaches disk and no speaker pass runs. Switching off mid-session deletes that session's file; switching on waits for the next session, since a file that starts mid-session would misplace every segment.
    var keepAudioForSpeakerPass: Bool {
        get { settings.bool(JotDefaultsKey.keepAudioForSpeakerPass) }
        set { save(JotDefaultsKey.keepAudioForSpeakerPass, newValue) }
    }
    var cleanUpTranscriptions: Bool {
        get { settings.bool(JotDefaultsKey.cleanUpTranscriptions) }
        set { save(JotDefaultsKey.cleanUpTranscriptions, newValue) }
    }
    var cleanUpDictation: Bool {
        get { settings.bool(JotDefaultsKey.cleanUpDictation) }
        set { save(JotDefaultsKey.cleanUpDictation, newValue) }
    }
    /// The four grouping and speaker values as one, for the sliders and the code that groups rows.
    var tuning: TranscriptionTuning {
        get { settings.tuning }
        set {
            let previous = settings.tuning
            settings.setTuning(newValue)
            let saved = settings.tuning
            objectWillChange.send()
            guard saved != previous else { return }
            library.refreshHistory()
            if saved.paragraphPause != previous.paragraphPause { library.reloadLive() }
        }
    }

    @Published var lifecycle = ServiceLifecycle()
    @Published var dictationRequested = UserDefaults.standard.bool(forKey: JotDefaultsKey.dictationRequested)
    @Published private(set) var shortcut = ShortcutPreferences().load()
    @Published private(set) var suggestionShortcut = SuggestionShortcutPreferences().load()
    var canRequestSuggestion: Bool { suggestionBlocker == nil }
    /// Why a suggestion cannot be requested right now, in the words the card shows.
    var suggestionBlocker: String? {
        if preparingUpdate { return "Jot is finishing the update." }
        if switchingInput { return "Jot is switching microphones." }
        if !suggestionsEnabled { return "Suggestions are off in General." }
        if let reason = dependencies.intelligenceAvailability().suggestionBlocker { return reason }
        if dictation.isActive || dictation.isPending { return "No suggestion while a dictation is in progress." }
        if diagnosticActive { return "No suggestion while diagnostics run." }
        if preparing { return "No suggestion while Jot is loading models." }
        if cleanup.isRunning { return "Jot is cleaning up speech; double-tap again in a moment." }
        return nil
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
        input.dictationEnabled = dictationEnabled
        if dictationEnabled || (suggestionsEnabled && DictationInput.accessibilityGranted) {
            _ = input.enable()
        } else { input.disable() }
        input.fnSuggestionsEnabled = suggestionsEnabled
    }
    var canChangeShortcut: Bool { !dictation.isActive && !dictation.isPending }
    var canChangeInput: Bool { !switchingInput && !preparingUpdate }
    /// Internal replacement barrier. The Update button is always usable; its operation waits for this after saving capture.
    var canInstallUpdate: Bool {
        !capture.running && !dictation.isActive && !dictation.isPending && !dictation.recoveryRunning && !diagnosticActive &&
        transcriber.isIdle && !preparing && !pauseRequested && !cleanup.isRunning && !library.isRelabeling &&
        !speakers.hasPendingPasses && !switchingInput && unloading == nil && storeExecutor.pendingCount == 0
    }
    @Published var showingSavedDictation = false
    @Published var recoveryNotice = ""
    @Published private(set) var cleanupAvailability = TranscriptCleanup.availability

    private var shortcutStateReady = false
    func refreshShortcutEligibility() {
        if shortcutStateReady { input.refreshShortcutState() }
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
    /// Screen Recording, for the optional window image. macOS may need Jot reopened before a new permission applies.
    @Published private(set) var screenRecordingAllowed = WindowImageCapture.permitted
    @Published private(set) var cachedModelBytes = ModelCache.bytesOnDisk()
    /// Set when a resume would download models that are not cached yet. The view asks before any download starts.
    @Published var downloadPrompt: Int64?
    /// Title of the meeting being recorded; nil when ambient is off or was started without a name.
    @Published private(set) var meetingTitle: String?
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

    @Published var dictationEnabled = false
    @Published var droppedSeconds = 0.0
    /// Not published: it changes on every audio drain, and each published assignment tells the window to redraw.
    var lastAudioAt: Date?
    /// Resume is loading models or restarting the microphone.
    var preparing: Bool { preparation != nil }
    lazy var pipeline = SpeechPipeline(settings: settings)
    private let sampler = ResourceSampler()
    /// A sampler measures CPU since its previous sample, and `sampler` also samples when a recognition finishes. Sharing it would leave each recognition's CPU out of the next readout, so the readout has its own, sampled only at launch and by the tick.
    private let readoutSampler = ResourceSampler()
    private let keepAwake = KeepAwakeAssertion()
    private var server: LocalServiceServer?
    /// Held from before the store opens until quit. See DirectoryLock.
    private var directoryLock: DirectoryLock?
    var suggestionHistory: SuggestionHistory?
    private var timer: Timer?
    /// A `jot` file diagnostic is running; app replacement waits for it to settle.
    @Published var diagnosticActive = false { didSet { refreshShortcutEligibility() } }
    /// Screens read `preparing` from this, so a change redraws them the way the stored flag's mode update did.
    private var preparation: Task<Void, Never>? {
        willSet { objectWillChange.send() }
        didSet { refreshShortcutEligibility() }
    }
    private var pausing: Task<Void, Never>?
    private var unloading: Task<Void, Never>?
    /// A hold while paused: the microphone starts for this hold alone. See `holdBegan`.
    private var holdCapture: Task<Void, Never>?
    /// The microphone is on for a held dictation only; release stops it and Jot is paused again.
    private(set) var holdOnlyCapture = false
    private var sleepResume = SleepResumePolicy()
    var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    /// The Pause button, the menu icon and the shortcut button read this, and a pause can be requested with no other published change until capture stops, so a change redraws them.
    private(set) var pauseRequested = false { willSet { objectWillChange.send() } }
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.holdBegan() }, onStop: { [weak self] released in self?.holdEnded(releasedAt: released) })
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
            self.suggestions.refuse(self.suggestionBlocker ?? "Suggestions are not available on this keyboard layout.",
                                    anchorToField: self.suggestionsEnabled && self.dependencies.intelligenceAvailability() == .available)
        }
        result.onSuggestionAccept = { [weak self] in self?.suggestions.accept() }
        result.onSuggestionDismiss = { [weak self] action in self?.suggestions.dismiss(action: action) }
        result.startBlocker = { [weak self] in
            guard let self else { return "Jot is shutting down." }
            if self.preparingUpdate { return "Jot is finishing the update." }
            if self.switchingInput { return "Jot is switching microphones." }
            return DictationReadiness.blocker(phase: self.lifecycle.phase, modelsReady: self.modelState == .ready,
                ambientEnabled: self.ambientEnabled, pauseRequested: self.pauseRequested, dictationPending: self.dictation.isPending,
                dictationActive: self.dictation.isActive, diagnosticActive: self.diagnosticActive,
                microphoneStarting: self.preparing || self.holdCapture != nil)
        }
        result.onError = { [weak self] error in
            self?.notice = error.localizedDescription
            if self?.dictation.isActive == true {
                self?.recoveryNotice = "Speech is still being saved. Choose Review saved dictation to copy it."
            }
        }
        result.onDiscardTap = { [weak self] in self?.holdDiscarded() }
        shortcutStateReady = true
        return result
    }()

    /// `askPermissions: false` while first-run setup is open: setup asks for each permission on the page that explains it.
    func launch(askPermissions: Bool = true) async {
        markPerformance(.launch)
        resourceReadout.snapshot = readoutSampler.sample()
        capture.watchDevices()
        do { vocabulary = try vocabularyPreferences.load() }
        catch { vocabularyLoadError = "Could not load vocabulary. Saved entries were preserved. " + error.localizedDescription }
        do {
            // The lock comes before the store: only one Jot may open writable history and own capture.
            directoryLock = try DirectoryLock(directory: JotPaths.directory)
            let opened = try await storeExecutor.perform { try TranscriptStore() }
            library.store = opened
            // Diagnostics are best effort; a telemetry schema failure must not stop capture or history access.
            suggestionHistory = try? await storeExecutor.perform { try SuggestionHistory(sharing: opened) }
            // Converts interrupted holds with the vocabulary loaded above.
            try await dictation.finalizeInterruptedAttempts()
            speakers.speakerStore = try await storeExecutor.perform { try SpeakerPassStore(sharing: opened) }
            speakers.peopleStore = try await storeExecutor.perform { try PeopleStore(sharing: opened) }; speakers.refreshPeople()
            // The user's voice is kept independently from transcript schema changes.
            speakers.userVoiceStore = UserVoiceStore(directory: JotPaths.directory); speakers.loadUserVoice()
            let service = LocalServiceServer { [weak self] data in
                guard let self else { return Data("{\"ok\":false,\"error\":\"Service unavailable\"}".utf8) }
                return await self.handle(data)
            }
            try service.start(); server = service
            library.refreshRecent(); library.refreshSessions()
            if let attempt = try await storeExecutor.perform({ try opened.latestRecoverableDictationAttempt() }) {
                recoveryNotice = attempt.hasGap
                    ? "Partial dictation was saved. Choose Review saved dictation to copy the recognized portion."
                    : "Choose Review saved dictation to copy the saved text."
            }
            for stale in SessionAudioFile.discardStale(except: timeline.sessionID) { recordEvent(.audioDiscarded, "Session audio left by an earlier run was deleted.", session: stale) }
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.modelUpdateChecks),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            meetingTitle = UserDefaults.standard.string(forKey: JotDefaultsKey.updateMeetingTitle)
            UserDefaults.standard.removeObject(forKey: JotDefaultsKey.updateMeetingTitle)
            if UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared) {
                // The models load at launch either way, so Resume is immediate; a launch left paused only leaves the microphone off.
                prepare(listen: !UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused))
            }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
        // A second Jot stands down entirely: no models, no key tap, no socket. The window shows the notice and Quit.
        guard directoryLock != nil else { return }
        if askPermissions { promptForPermissionsAtLaunch() }
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
                if self.switchingInput || self.preparingUpdate || self.capture.shouldIgnoreConfigurationChange() { return }
                self.recordEvent(.deviceChange, "Audio input configuration changed."); self.pause(automatic: true); self.notice = "Audio input changed. Resume when ready."
            }
        })
    }

    /// Paused means no intake: the microphone is off, whether the models are loaded (the normal case after Pause) or not
    /// (before the first Resume, or after Unload Models). A Pause still saving speech counts as paused and changing.
    var isPaused: Bool { pauseRequested || listeningState.isPaused || microphoneOff }
    var isTransitioning: Bool { pauseRequested || listeningState.isChanging || preparing }
    /// The speech models are resident, so Resume only starts the microphone.
    var modelsLoaded: Bool { listeningState.modelsLoaded }
    var keepAwakeActive: Bool { keepAwake.isActive }

    private func resumeAfterSleepIfReady() {
        guard !preparingUpdate, !switchingInput else { return }
        guard sleepResume.takeResume(paused: !ambientEnabled && !pauseRequested && !preparing) else { return }
        guard ambientRequested else { return }
        capture.refreshInputDevices()
        prepare()
    }

    /// Audio drains five times a second while the microphone runs; otherwise the tick only does its once-a-second status work.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = ambientEnabled ? 0.2 : 5.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = interval / 5
        // An open menu or a live window resize takes the run loop out of its default mode; common modes keep the audio draining then.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Resume. The first resume downloads models, so it asks before spending bandwidth. With the models already loaded, which
    /// is the normal case after Pause, only the microphone starts. `listen: false` loads the models and leaves the microphone
    /// off, for a launch that was left paused.
    func prepare(confirmingDownload: Bool = false, listen: Bool = true) {
        guard !preparingUpdate else { notice = "Finishing the update…"; return }
        guard !pauseRequested else {
            notice = "Pause is still saving captured speech. Resume when it finishes."
            return
        }
        guard !diagnosticActive else {
            notice = "Wait for the file diagnostic to finish before resuming listening."
            return
        }
        sleepResume.cancel()
        if !switchingInput { capture.resetInputSearch() }
        if listen {
            ambientRequested = true
            UserDefaults.standard.set(false, forKey: JotDefaultsKey.servicePaused)
            markPerformance(.resume)
        }
        cachedModelBytes = ModelCache.bytesOnDisk()
        if cachedModelBytes == 0 && !confirmingDownload && !modelsLoaded {
            downloadPrompt = ModelCache.expectedBytes
            return
        }
        downloadPrompt = nil
        guard let token = lifecycle.beginStart() else {
            if microphoneOff && ambientRequested { restartMicrophone() }
            return
        }
        markPerformance(.modelLoadStarted)
        notice = "Loading models…"
        preparation = Task {
            do {
                try await dependencies.prepareModels(pipeline)
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                markPerformance(.modelsReady)
                UserDefaults.standard.set(true, forKey: JotDefaultsKey.modelsPrepared)
                cachedModelBytes = ModelCache.bytesOnDisk()
                if dictationRequested { await enableDictation() }
                if ambientRequested { try await activateAmbient(); try await continueMeeting() }
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

    /// Models are loaded and the microphone is off: after Pause, or when it never started. Resume has nothing to reload and
    /// only starts the capture. False while a start is under way.
    var microphoneOff: Bool { listeningState == .ready && !pauseRequested && !preparing }

    /// Resume with the models loaded: the dictation shortcut if it is on, the microphone, and a continued meeting.
    private func restartMicrophone() {
        preparation = Task {
            do {
                if dictationRequested { await enableDictation() }
                try await activateAmbient(); try await continueMeeting()
            } catch { notice = error.localizedDescription }
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

    /// Setup's Download button: fetches and loads the models with the microphone off. Jot stays paused, across a relaunch too,
    /// until the user chooses Resume, so a download never starts listening.
    func prepareModelsOnly() {
        guard !ambientEnabled, !preparing, !preparingUpdate, !pauseRequested else { return }
        ambientRequested = false
        UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        prepare(confirmingDownload: true, listen: false)
    }

    /// Assigns only a change, since the tick calls this every second.
    func refreshPermissions() {
        let microphone = dependencies.microphoneAuthorization()
        if micPermission != microphone { micPermission = microphone }
        let accessibility = DictationInput.accessibilityGranted
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        let screen = WindowImageCapture.permitted
        if screenRecordingAllowed != screen { screenRecordingAllowed = screen }
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
        if micPermission != .authorized { fixMicrophonePermission(); return }
        fixAccessibilityPermission()
    }

    /// Asks for the microphone while macOS still allows asking, otherwise opens its settings pane. Setup's microphone page uses it too.
    func fixMicrophonePermission() {
        if micPermission == .notDetermined { Task { _ = await requestMic() }; return }
        openSettings("Privacy_Microphone")
    }

    /// macOS's own Accessibility prompt, and the pane where Jot is switched on. Setup's dictation page uses it too.
    func fixAccessibilityPermission() {
        input.requestAccessibility()
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func enableDictation() async {
        dictationRequested = true; UserDefaults.standard.set(true, forKey: JotDefaultsKey.dictationRequested)
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token) else { return }
        guard await requestMic(), lifecycle.acceptsWork(token), dictationRequested else { return }
        if !DictationInput.accessibilityGranted { input.requestAccessibility() }
        dictationEnabled = input.enable()
        input.dictationEnabled = dictationEnabled
        if !dictationEnabled { notice = "Enable Accessibility access in System Settings, then switch dictation on again." }
    }

    func disableDictation() {
        dictationRequested = false; UserDefaults.standard.set(false, forKey: JotDefaultsKey.dictationRequested)
        if dictation.isActive { dictation.end() }
        suggestions.dismiss(action: .settingsChanged)
        input.disable(); dictationEnabled = false
        updateSuggestionMonitoring()
    }

    // MARK: Work that spans the owned objects

    /// A click owns the stop/save/restart sequence; the user never needs to press Pause first.
    func setInput(uid: String, automatic: Bool = false) {
        guard canChangeInput else { return }
        if !automatic { capture.resetInputSearch() }
        switchingInput = true
        // Stop immediately and flush the tail before changing the device. Automatic pause retains listening and meeting intent.
        pause(automatic: true, runSpeakerPass: timeline.lastAmbientRowAt != nil)
        inputChange = Task {
            if let pausing { await pausing.value }
            if let unloading { await unloading.value }
            guard !Task.isCancelled else { switchingInput = false; return }
            do {
                try capture.setInput(uid: uid)
                notice = "Microphone changed to \(capture.inputName)."
            } catch { notice = error.localizedDescription }
            if ambientRequested && !preparingUpdate {
                prepare()
                await waitForPreparation()
            }
            switchingInput = false; inputChange = nil
            if automatic && !capture.running && ambientRequested,
               let next = capture.nextAutomaticInput(failed: true) { setInput(uid: next, automatic: true) }
        }
    }

    func waitForInputChange() async {
        while let inputChange { await inputChange.value }
    }

    /// Called only after the downloaded update has passed verification. New intake stays blocked until swap or failure.
    func prepareForUpdate() async throws {
        guard !preparingUpdate else { throw JotError.message("An update is already finishing.") }
        preparingUpdate = true
        resumeAfterUpdate = ambientRequested
        sleepResume.cancel()
        pause(automatic: true, runSpeakerPass: timeline.lastAmbientRowAt != nil)
        let deadline = ContinuousClock.now + .seconds(60)
        while !canInstallUpdate {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw JotError.message("Captured speech is still being saved. The update could not finish yet; try Update again.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The next app launch resumes only the listening the update interrupted, including its meeting title.
        UserDefaults.standard.set(!resumeAfterUpdate, forKey: JotDefaultsKey.servicePaused)
        if resumeAfterUpdate, let meetingTitle {
            UserDefaults.standard.set(meetingTitle, forKey: JotDefaultsKey.updateMeetingTitle)
        } else { UserDefaults.standard.removeObject(forKey: JotDefaultsKey.updateMeetingTitle) }
    }

    func cancelUpdatePreparation() {
        guard preparingUpdate else { return }
        preparingUpdate = false
        UserDefaults.standard.removeObject(forKey: JotDefaultsKey.updateMeetingTitle)
        if resumeAfterUpdate {
            // A timeout can occur while Pause still drains: resume only after that work has settled.
            updateRecovery?.cancel()
            updateRecovery = Task {
                if let pausing { await pausing.value }
                guard !Task.isCancelled, ambientRequested else { return }
                prepare()
                updateRecovery = nil
            }
        }
    }

    /// The session being recorded belongs to Live until capture stops.
    func canDeleteSession(_ id: String) -> Bool { !(id == timeline.activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        try await library.deleteSession(id)
    }

    func regroupSession(_ id: String) async throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        try await library.regroupSession(id) { try await speakers.segments(sessionID: id) }
        speakers.didRegroup(id)
    }

    func deleteHistoryCard(_ item: Transcript) async throws {
        try await library.deleteHistoryCard(item, discard: dictation.discard(ids:))
    }

    func clearHistory() async throws {
        try await library.clearHistory(discardAttempt: dictation.discardForHistoryReset)
    }

    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]? = nil) async {
        // The name is saved before the voice is remembered, so Live shows it even when remembering the voice fails.
        defer { library.reloadLive() }
        do { try await speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: voice) }
        catch { notice = error.localizedDescription }
    }

    /// The session's last audio block is recognized and its cleanup has landed, so its rows will not change under a relabel.
    func sessionIsSettled(_ id: String) -> Bool { transcriber.isDone(session: id) && !cleanup.isCleaning(session: id) }

    /// Models loaded, microphone on, no pause under way.
    var canHoldDictation: Bool { listeningState.modelsLoaded && ambientEnabled && !pauseRequested && !switchingInput && !preparingUpdate }

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
            let store = library.store, id = timeline.sessionID
            try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: trimmed) }.value
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
    func setSessionTitle(_ id: String, title: String) async throws {
        let store = library.store
        guard !(await library.waitForDeletion(id)) else { throw JotError.message("Session was deleted.") }
        try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: title) }.value
        library.refreshSessions()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle != nil, id == timeline.activeSessionID, !trimmed.isEmpty { meetingTitle = trimmed }
    }

    /// A meeting kept through an automatic pause records on into a new session under the same name. The earlier part stays in Sessions, and TranscriptExport.write adds " (2)" to a duplicate file name.
    private func continueMeeting() async throws {
        guard let meetingTitle, ambientEnabled else { return }
        let store = library.store, id = timeline.sessionID
        try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: meetingTitle) }.value
        library.refreshSessions()
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
        let store = library.store
        guard (try? await storeExecutor.perform { try store?.session(id: id).isEmpty }) == false else { return nil }
        do {
            let url = try await library.exportSession(id)
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
        ambientEnabled = true; updateKeepAwakeAssertion(); scheduleTimer()
        if !switchingInput { livePresentationRevision &+= 1 }
        recordEvent(.started, "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        guard !preparingUpdate else { throw JotError.message("Jot is finishing the update.") }
        ambientRequested = true
        UserDefaults.standard.set(false, forKey: JotDefaultsKey.servicePaused)
        if lifecycle.phase == .paused || lifecycle.phase == .failed { prepare() }
        if let preparation { await preparation.value }
        guard lifecycle.phase == .ready else { throw JotError.message("The service is not ready. Wait for Pause to finish, then Resume.") }
        try await activateAmbient()
    }

    /// Stop the microphone immediately and save already captured chunks. The models stay loaded, so Resume only starts the
    /// microphone again; `unloadModels()` releases them on request. Automatic pauses keep listening intent and a running
    /// meeting for Resume. Nothing to do when the microphone is already off and no start is under way.
    func pause(automatic: Bool = false, runSpeakerPass: Bool = true) {
        if !automatic {
            updateRecovery?.cancel(); updateRecovery = nil
            sleepResume.cancel()
            capture.resetInputSearch()
            // A Pause clicked during a device change also cancels its automatic resume.
            ambientRequested = false
            UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        }
        guard !pauseRequested, ambientEnabled || ambientRequested || preparing || holdCapture != nil || capture.running else { return }
        suggestions.dismiss(action: .serviceStopped)
        pauseRequested = true
        markPerformance(.pause)
        UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        capture.stop()
        drainAudio()
        if ambientEnabled { timeline.flushAmbient(final: true) }
        updateKeepAwakeAssertion()
        if ambientEnabled { recordEvent(.paused, "Service paused.") }
        timeline.endSessionAudio(runPass: automatic && runSpeakerPass)
        let outcome = PauseOutcome(automatic: automatic, ambientRequested: ambientRequested, meetingTitle: meetingTitle)
        ambientRequested = outcome.ambientRequested; meetingTitle = outcome.meetingTitle
        let holdingTask = holdCapture
        holdingTask?.cancel(); holdOnlyCapture = false
        // The dictation tap stays on: with the models loaded, a hold while paused runs the microphone for the hold.
        updateSuggestionMonitoring()
        if dictation.isActive { dictation.end() }
        let loadingTask = preparation, fileTask = diagnostic
        loadingTask?.cancel(); fileTask?.cancel()
        notice = transcriber.isIdle ? "" : "Saving captured speech before Pause…"
        pausing = Task {
            await holdingTask?.value
            await loadingTask?.value
            _ = try? await fileTask?.value
            while !transcriber.isIdle {
                transcriber.kick()
                try? await Task.sleep(for: .milliseconds(20))
            }
            await dictation.waitForRecovery()
            // Optional text-only cleanup may finish after capture stops. Original recognition is already durable; no microphone is retained.
            ambientEnabled = false; transcriber.queuedSeconds = 0
            notice = outcome.endedMeeting ? "Meeting stopped. Its transcript is in Sessions." : ""
            pauseRequested = false; pausing = nil
            scheduleTimer()
            resumeAfterSleepIfReady()
        }
    }

    /// Frees the speech models' memory: the Unload Models menu item and `jot models unload`. Listening stops first if it is
    /// on. Resume afterwards loads the models again before the microphone starts. Nothing else unloads them but Quit.
    func unloadModels() {
        guard unloading == nil, lifecycle.phase != .paused, lifecycle.phase != .pausing else { return }
        if ambientEnabled || ambientRequested || preparing { pause() }
        unloading = Task {
            if let pausing { await pausing.value }
            while pauseRequested { try? await Task.sleep(for: .milliseconds(20)) }
            // A pause during model loading already failed the start and released the models; the generation still moves on.
            guard let token = lifecycle.beginPause() else { unloading = nil; return }
            notice = "Releasing models…"; scheduleTimer()
            await dependencies.unloadModels(pipeline)
            if lifecycle.finishPause(token) {
                preparation = nil; notice = ""
                // No models, no dictation: the tap stays on only for suggestions.
                dictationEnabled = false; updateSuggestionMonitoring()
                markPerformance(.modelsUnloaded); scheduleTimer()
            }
            unloading = nil
        }
    }

    // MARK: A hold while paused

    /// The dictation shortcut went down. Listening: the hold begins at once. Paused with the models loaded: the microphone
    /// starts for this hold, in a session of its own, and the hold begins when it is up. A release before then stops it again.
    func holdBegan() {
        guard !switchingInput, !preparingUpdate else { return }
        if canHoldDictation { dictation.begin(); return }
        guard microphoneOff, holdCapture == nil else { return }
        holdOnlyCapture = true
        holdCapture = Task {
            defer { holdCapture = nil }
            do {
                try await startHoldCapture()
                guard !Task.isCancelled, holdOnlyCapture, ambientEnabled else { stopHoldCapture(); return }
                dictation.begin()
            } catch {
                holdOnlyCapture = false
                notice = error.localizedDescription
            }
        }
    }

    /// The shortcut came up: the hold ends as always, and a hold-only microphone stops.
    func holdEnded(releasedAt released: Double) {
        dictation.end(releasedAt: released)
        if holdOnlyCapture { stopHoldCapture() }
    }

    /// A short tap discards the held intent, and a hold-only microphone stops.
    func holdDiscarded() {
        dictation.cancelTap()
        if holdOnlyCapture { stopHoldCapture() }
    }

    private func startHoldCapture() async throws {
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token), !diagnosticActive, !pauseRequested, !ambientEnabled else {
            throw JotError.message("The microphone cannot start for dictation right now.")
        }
        guard await requestMic() else { throw JotError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), !pauseRequested, !ambientEnabled, !Task.isCancelled else { return }
        lastAudioAt = dependencies.now()
        guard try await capture.startRetrying(shouldContinue: { lifecycle.acceptsWork(token) && !pauseRequested && !Task.isCancelled }) else { return }
        guard !Task.isCancelled else { capture.stop(); return }
        // No audio file: a dictation of one voice needs no speaker pass.
        timeline.beginSession(at: dependencies.now(), withAudio: false)
        ambientEnabled = true; updateKeepAwakeAssertion(); scheduleTimer()
        if !switchingInput { livePresentationRevision &+= 1 }
        recordEvent(.started, "Microphone started for a held dictation while paused.")
    }

    /// Ends a hold-only capture: the microphone stops, the hold's session closes, and Jot is paused again. If listening was
    /// requested meanwhile, the microphone stays on and the session simply continues.
    private func stopHoldCapture() {
        holdOnlyCapture = false
        holdCapture?.cancel()
        guard !ambientRequested, ambientEnabled || capture.running else { return }
        capture.stop(); drainAudio()
        timeline.flushAmbient(final: true)
        timeline.endSessionAudio(runPass: false)
        ambientEnabled = false; updateKeepAwakeAssertion(); scheduleTimer()
        recordEvent(.paused, "Microphone stopped after the held dictation.")
        transcriber.kick()
    }

    private func tick() {
        // Paused keeps the phase ready with the microphone stopped; nothing is drained then.
        if lifecycle.phase == .ready, ambientEnabled { drainAudio() }
        tickCount += 1
        if dependencies.now().timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = dependencies.now(); refreshPermissions()
            resourceReadout.snapshot = readoutSampler.sample()
            // A published assignment tells the window to redraw even when the value is the same, so only changes are assigned.
            let availability = dependencies.intelligenceAvailability()
            if cleanupAvailability != availability {
                cleanupAvailability = availability
                refreshShortcutEligibility()
            }
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
        if automaticMicrophone, ambientEnabled, !pauseRequested, !preparing, canChangeInput,
           !dictation.isActive, !dictation.isPending, let next = capture.nextAutomaticInput() {
            setInput(uid: next, automatic: true)
        }
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
        await storeExecutor.flush()
        await library.waitForReads()
    }

    /// Counts and state only; transcript and field contents never enter diagnostics.
    var recoveryDiagnostics: [String: Any] {
        [
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
        let store = library.store
        let event = CaptureEvent(sessionID: session ?? timeline.sessionID, kind: kind.rawValue, detail: detail, durationSeconds: duration)
        let write = storeExecutor.submit { try store?.appendEvent(event) }
        Task {
            do { _ = try await write.value; library.refreshEvents() }
            catch { notice = "Could not save capture event: \(error.localizedDescription)" }
        }
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
        inputChange?.cancel(); updateRecovery?.cancel()
        modelCheck?.cancel(); preparation?.cancel(); transcriber.cancel(); diagnostic?.cancel(); pausing?.cancel(); unloading?.cancel(); holdCapture?.cancel()
        suggestions.dismiss(action: .serviceStopped)
        timer?.invalidate(); dictation.releaseFieldEffects(); input.disable(); capture.stop(); updateKeepAwakeAssertion(); server?.stop()
        capture.stopWatching()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    private func updateKeepAwakeAssertion() {
        keepAwake.setActive(keepMacAwakeWhileListening && ambientEnabled && capture.running)
    }
}
