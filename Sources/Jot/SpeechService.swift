import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import JotEngine

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
        countUsage: { [weak self] in self?.library.countUsage($0) },
        agentContext: agentContext,
        allowed: { [weak self] in self?.canRequestSuggestion == true },
        readsScreen: { [weak self] in self?.suggestionScreenContext == true },
        includesWindowImage: { [weak self] in self?.suggestionWindowImage == true },
        window: { [weak self] in TimeInterval((self?.suggestionWindowMinutes ?? 10) * 60) },
        matchesHeardSpeech: { [weak self] in self?.suggestionHeardMatches == true },
        userVoice: { [weak self] in self?.speakers.userVoice },
        model: ChosenModel(.suggestions, settings: settings),
        notice: { [weak self] in self?.notice = $0 })
    lazy var timeline: ListeningTimeline = ListeningTimeline(settings: settings, library: library, speakers: speakers,
        transcriber: transcriber, now: dependencies.now,
        isListening: { [unowned self] in ambientEnabled }, isDictating: { [unowned self] in dictation.isActive },
        receivedAudio: { [unowned self] in lastAudioAt = $0 }, droppedAudio: { [unowned self] in droppedSeconds += $0 },
        recordEvent: { [unowned self] in recordEvent($0, $1, duration: $2, session: nil) },
        setNotice: { [unowned self] in notice = $0 }, markDictationGap: { [weak self] in self?.dictation.markGap($0) })
    lazy var cleanup: LiveCleanup = LiveCleanup(owner: self, library: library, settings: settings,
        clean: dependencies.cleanup, availability: { [unowned self] in modelAvailability(.cleanup) },
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
        recordedRows: { [weak self] job, rows in
            guard let self, job.sessionID == self.timeline.sessionID else { return }
            self.timeline.lastAmbientRowAt = self.dependencies.now()
            if let row = rows.last(where: { $0.mode == "ambient" }) {
                self.lastAmbientRow = row
                if self.settings.bool(JotDefaultsKey.shareTranscriptPreview) { ControlEvents.signal() }
            }
        }, recognitionCompleted: { [weak self] in self?.dictation.updateAttemptText(for: $0) },
        recognitionFailed: { [weak self] in self?.dictation.noteRecognitionFailure(for: $0) })

    init(dependencies: SpeechServiceDependencies = .live, settings: JotSettings = .standard) {
        self.dependencies = dependencies
        self.settings = settings
        cleanupAvailability = ChosenModel(.cleanup, settings: settings).availability(orApple: dependencies.intelligenceAvailability())
        capture = CaptureController(microphone: dependencies.makeMicrophone(), retry: dependencies.microphoneRetry,
            availableDevices: dependencies.availableInputs, defaultDeviceUID: dependencies.defaultInputUID)
        capture.onNotice = { [weak self] in self?.notice = $0 }
    }
    /// A fresh listening start opens Live; input changes preserve the current tab.
    @Published private(set) var livePresentationRevision = 0
    @Published private(set) var switchingInput = false { didSet { refreshShortcutEligibility() } }
    @Published private(set) var preparingUpdate = false { didSet { refreshShortcutEligibility() } }
    private var inputChange: Task<Void, Never>?
    /// Whether listening was on when an update began: the relaunch, or a failed update, resumes it.
    private lazy var updateHandoff = UpdateHandoff()

    /// The one store. Nothing in SpeechService copies a value out of it; the setting properties in
    /// SpeechService+Settings.swift read it, and each setter writes it and then calls `settingChanged`, which applies the side
    /// effect the setting has and redraws the screens. `jot settings` writes the same store over the socket and calls
    /// `settingChanged` too, so a change applies at once either way. `jot lab` passes a store of its own, so a lab run never
    /// reads or writes the app's settings.
    let settings: JotSettings

    @Published var lifecycle = ServiceLifecycle() { didSet { ControlEvents.signal() } }
    @Published var dictationRequested = UserDefaults.standard.bool(forKey: JotDefaultsKey.dictationRequested)
    @Published private(set) var shortcut = ShortcutPreferences().load()
    @Published private(set) var suggestionShortcut = SuggestionShortcutPreferences().load()
    var canRequestSuggestion: Bool { suggestionBlocker == nil }
    /// Why a suggestion cannot be requested right now, in the words the card shows.
    var suggestionBlocker: String? {
        if preparingUpdate { return "Jot is finishing the update." }
        if switchingInput { return "Jot is switching microphones." }
        if !suggestionsEnabled { return "Suggestions are off in General." }
        if let reason = modelAvailability(.suggestions).suggestionBlocker { return reason }
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
    func updateSuggestionMonitoring() {
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
        if shortcutStateReady { input.refreshShortcutState(); ControlEvents.signal() }
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
    /// Resume or Start asked for listening while a hold-only microphone was on. An automatic pause keeps
    /// `ambientRequested` set without anyone asking, so that alone must not keep the microphone after the hold.
    private var listeningRequestedDuringHold = false
    @Published private(set) var ambientEnabled = false { didSet { ControlEvents.signal() } }
    /// Where listening stands, read from the lifecycle, the microphone and a held dictation. `jot status` reports its mode and model state.
    var listeningState: ListeningState {
        ListeningState(phase: lifecycle.phase, generation: lifecycle.generation, microphoneOn: ambientEnabled, dictationActive: dictation.isActive)
    }
    var mode: String { listeningState.mode }
    var modelState: ListeningState.Models { listeningState.models }
    /// What Jot tells the person. Assigning it directly reads as `ControlNotice.other`; `post(_:_:)` names the code.
    @Published var notice = "" {
        didSet { noticeCode = notice.isEmpty ? nil : (stagedNoticeCode ?? ControlNotice.other); stagedNoticeCode = nil }
    }
    /// The notice's code for `speech.controls` version 2. The text never leaves Jot over the control surface.
    private(set) var noticeCode: ControlNotice? { didSet { if noticeCode != oldValue { ControlEvents.signal() } } }
    private var stagedNoticeCode: ControlNotice?
    /// Shows `text` as the notice and `code` as what it is about.
    func post(_ code: ControlNotice, _ text: String) { stagedNoticeCode = code; notice = text }
    @Published var modelUpdates = ModelUpdate.defaults
    @Published var checkingModels = false
    @Published var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibilityGranted = DictationInput.accessibilityGranted
    /// macOS's own Fn/Globe action, which also fires on every Fn hold unless it is Do Nothing.
    @Published private(set) var fnKeyUsage = SpeechService.readFnKeyUsage()
    /// Screen Recording, for the optional window image. macOS may need Jot reopened before a new permission applies.
    @Published private(set) var screenRecordingAllowed = WindowImageCapture.permitted
    @Published private(set) var cachedModelBytes = ModelCache.bytesOnDisk()
    /// Set when a resume would download models that are not cached yet. The view asks before any download starts.
    @Published var downloadPrompt: Int64?
    /// Title of the meeting being recorded; nil when ambient is off or was started without a name.
    /// Set by the meeting calls in SpeechService+Meetings.swift, by Pause and by the update restore.
    @Published var meetingTitle: String? {
        didSet {
            if meetingTitle == nil { meetingParts = []; meetingStartedAt = nil }
            else if oldValue == nil { meetingStartedAt = dependencies.now() }
            ControlEvents.signal()
        }
    }
    /// The newest row saved while listening, for the Island's transcript preview. Memory only.
    var lastAmbientRow: Transcript?
    /// When the running meeting began. Renames and the automatic pauses that keep a meeting keep its start; after an
    /// update relaunch it restarts from the restore, since the handoff carries only the title.
    private(set) var meetingStartedAt: Date?
    /// Sessions the running meeting recorded into, oldest first: an automatic pause continues it in a new session.
    /// End meeting exports each of them. Memory only; after an update relaunch only the parts from then on are known.
    var meetingParts: [String] = []
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
    let diagnosticsBegan = ProcessInfo.processInfo.systemUptime
    /// Ephemeral control-surface sequence; never a transcript/session identifier.
    var controlSequence: UInt64 = 0

    @Published var dictationEnabled = false
    @Published var droppedSeconds = 0.0
    /// Not published: it changes on every audio drain, and each published assignment tells the window to redraw.
    var lastAudioAt: Date?
    /// Resume is loading models or restarting the microphone.
    var preparing: Bool { preparation != nil }
    lazy var pipeline = SpeechPipeline(settings: settings)
    let sampler = ResourceSampler()
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
    lazy var pausedHold = PausedHold(startMicrophone: { [unowned self] in try await startHoldCapture() },
        stopMicrophone: { [unowned self] in stopHoldCapture() }, microphoneOn: { [unowned self] in ambientEnabled },
        beginDictation: { [unowned self] in dictation.begin() }, report: { [unowned self] in notice = $0.localizedDescription })
    /// The microphone is on for a held dictation only; release stops it and Jot is paused again.
    var holdOnlyCapture: Bool { pausedHold.isActive }
    private var sleepResume = SleepResumePolicy()
    var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    /// The Pause button, the menu icon and the shortcut button read this, and a pause can be requested with no other published change until capture stops, so a change redraws them.
    private(set) var pauseRequested = false { willSet { objectWillChange.send() } }
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    private var lastCapabilityCheckTime = Date.distantPast
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
                                    anchorToField: self.suggestionsEnabled && self.modelAvailability(.suggestions) == .available)
        }
        result.onSuggestionAccept = { [weak self] in self?.suggestions.accept() }
        result.onSuggestionDismiss = { [weak self] action in self?.suggestions.dismiss(action: action) }
        result.startBlocker = { [weak self] in
            guard let self else { return "Jot is shutting down." }
            if self.preparingUpdate { return "Jot is finishing the update." }
            if self.switchingInput { return "Jot is switching microphones." }
            if self.unloading != nil { return "Jot is releasing the models." }
            return DictationReadiness.blocker(phase: self.lifecycle.phase, modelsReady: self.modelState == .ready,
                ambientEnabled: self.ambientEnabled, pauseRequested: self.pauseRequested, dictationPending: self.dictation.isPending,
                dictationActive: self.dictation.isActive, diagnosticActive: self.diagnosticActive,
                microphoneStarting: self.preparing || self.pausedHold.isStarting, modelsDownloaded: self.modelsDownloaded)
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
            // Whether or not keepTuningAudio is on now: turning it off deletes nothing, so kept files age out here.
            await speakers.pruneTuningAudio()
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.modelUpdateChecks),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            meetingTitle = updateHandoff.takeMeetingTitle()
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
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCapabilities() }
        })
        // Low Power Mode changes the drain cadence; the chunk length is read at each drain.
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Listening that is still starting (models loading, microphone retries) resumes after wake as well; a
                // hold-only microphone while paused does not, unless Resume was asked for during the hold.
                let listening = self.ambientEnabled && (!self.holdOnlyCapture || self.listeningRequestedDuringHold)
                self.sleepResume.willSleep(ambientRunning: listening || (self.ambientRequested && self.preparing))
                let interrupted = self.ambientEnabled || self.preparing || self.capture.running
                if interrupted { self.recordEvent(.sleep, "Capture paused because the Mac is sleeping.") }
                self.pause(automatic: true)
                if interrupted { self.post(.pausedForSleep, "Paused for sleep.") }
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
                self.recordEvent(.deviceChange, "Audio input configuration changed."); self.pause(automatic: true); self.post(.microphoneChanged, "Audio input changed. Resume when ready.")
            }
        })
    }

    /// Paused means no intake: the microphone is off, whether the models are loaded (the normal case after Pause) or not
    /// (before the first Resume, or after Unload Models). A Pause still saving speech counts as paused and changing.
    var isPaused: Bool { pauseRequested || listeningState.isPaused || microphoneOff }
    var isTransitioning: Bool { pauseRequested || listeningState.isChanging || preparing }
    /// The speech models are resident, so Resume only starts the microphone.
    var modelsLoaded: Bool { listeningState.modelsLoaded }
    /// The speech models are resident or at least partly on disk. A fresh install has neither: nothing can listen or
    /// dictate until a download, and Resume asks before starting one.
    var modelsDownloaded: Bool { modelsLoaded || cachedModelBytes > 0 }
    var keepAwakeActive: Bool { keepAwake.isActive }

    private func resumeAfterSleepIfReady() {
        guard !preparingUpdate, !switchingInput else { return }
        guard sleepResume.takeResume(paused: !ambientEnabled && !pauseRequested && !preparing) else { return }
        guard ambientRequested else { return }
        capture.refreshInputDevices()
        prepare()
    }

    /// Starting capture replaces the quiet timer immediately; Fn never waits for
    /// paused housekeeping to start its microphone or finish saved speech.
    var tickInterval: TimeInterval { LowPowerListening.tickInterval(ambientEnabled ? 0.2 : 60) }

    /// Audio drains five times a second while listening. Paused housekeeping runs
    /// once a minute, while inference and recovery finish through their callbacks.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = tickInterval
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
            if pausedHold.isActive || pausedHold.isStarting { listeningRequestedDuringHold = true }
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
        post(.modelsLoading, "Loading models…")
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

    /// Explicit permission requests revalidate immediately; background housekeeping
    /// and foreground activation use refreshCapabilities instead.
    func refreshPermissions() {
        let microphone = dependencies.microphoneAuthorization()
        if micPermission != microphone { micPermission = microphone }
        let accessibility = DictationInput.accessibilityGranted
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        let screen = WindowImageCapture.permitted
        if screenRecordingAllowed != screen { screenRecordingAllowed = screen }
        let fnUsage = Self.readFnKeyUsage()
        if fnKeyUsage != fnUsage { fnKeyUsage = fnUsage }
    }

    /// The foreground path and slow background check share this change-only update.
    /// Request paths still consult live authorization/availability at point of use.
    func refreshCapabilities() {
        lastCapabilityCheckTime = dependencies.now()
        refreshPermissions()
        let availability = modelAvailability(.cleanup)
        if cleanupAvailability != availability {
            cleanupAvailability = availability
            refreshShortcutEligibility()
        }
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
        // Setup's Download loads the models with the microphone off: there is nothing to stop, and a pause would cancel the load.
        let modelsOnlyLoad = preparing && !ambientRequested && !ambientEnabled && !capture.running
        if !modelsOnlyLoad { pause(automatic: true, runSpeakerPass: timeline.lastAmbientRowAt != nil) }
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
        updateHandoff.begin(listening: ambientRequested)
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
        updateHandoff.commit(meetingTitle: meetingTitle)
    }

    func cancelUpdatePreparation() {
        guard preparingUpdate else { return }
        preparingUpdate = false
        updateHandoff.cancel(after: { [weak self] in self?.pausing },
                             stillWanted: { [weak self] in self?.ambientRequested ?? false },
                             resume: { [weak self] in self?.prepare() })
    }

    /// Models loaded, microphone on, no pause under way.
    var canHoldDictation: Bool { listeningState.modelsLoaded && ambientEnabled && !pauseRequested && !switchingInput && !preparingUpdate }

    /// Closes the audio chunk in progress so a held range starts or ends on an exact timeline boundary.
    func closeChunk() { drainAudio(); timeline.flushAmbient(final: true) }

    private func activateAmbient() async throws {
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token), !diagnosticActive, !pauseRequested else { throw JotError.message("Resume the service before listening.") }
        guard await requestMic() else { throw JotError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), ambientRequested, !pauseRequested else { return }
        guard !ambientEnabled else { return }
        let wasRunning = capture.running
        guard try await capture.startRetrying(shouldContinue: { lifecycle.acceptsWork(token) && ambientRequested && !pauseRequested }) else { return }
        // A start that needed retries took seconds; the four-second stall check counts from when the microphone came up.
        if !wasRunning { lastAudioAt = dependencies.now() }
        timeline.beginSession(at: dependencies.now())
        ambientEnabled = true; updateKeepAwakeAssertion(); scheduleTimer()
        if !switchingInput { livePresentationRevision &+= 1 }
        recordEvent(.started, "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        guard !preparingUpdate else { throw JotError.message("Jot is finishing the update.") }
        if pausedHold.isActive || pausedHold.isStarting { listeningRequestedDuringHold = true }
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
            updateHandoff.cancelRecovery()
            sleepResume.cancel()
            capture.resetInputSearch()
            // A Pause clicked during a device change also cancels its automatic resume.
            ambientRequested = false
            UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        }
        guard !pauseRequested, ambientEnabled || ambientRequested || preparing || pausedHold.isStarting || capture.running else { return }
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
        let holdingTask = pausedHold.interrupt()
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
            if outcome.endedMeeting { post(.meetingStopped, "Meeting stopped. Its transcript is in Sessions.") } else { notice = "" }
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
            // A hold while paused may still be recognizing with the microphone already off. Recognition needs the models,
            // and a block finished after beginPause() is discarded, so let it finish and the dictation settle first.
            // Capped, so a transcriber that never settles cannot hold Unload (and new holds) forever; past the cap the
            // models are released anyway, as before this wait existed.
            let settleDeadline = ContinuousClock.now + .seconds(10)
            while !transcriber.isIdle && lifecycle.phase == .ready && ContinuousClock.now < settleDeadline {
                transcriber.kick()
                try? await Task.sleep(for: .milliseconds(20))
            }
            if transcriber.isIdle { await dictation.waitForRecovery() }
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
        // Unload Models waits for the last hold to settle; a new one must not start the microphone under it.
        guard microphoneOff, unloading == nil else { return }
        // Cleared before the start task runs, so a Resume in the meantime still counts.
        if !pausedHold.isStarting { listeningRequestedDuringHold = false }
        pausedHold.begin()
    }

    /// The shortcut came up: the hold ends as always, and a hold-only microphone stops.
    func holdEnded(releasedAt released: Double) {
        dictation.end(releasedAt: released)
        pausedHold.release()
    }

    /// A short tap discards the held intent, and a hold-only microphone stops.
    func holdDiscarded() {
        dictation.cancelTap()
        pausedHold.release()
    }

    private func startHoldCapture() async throws {
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token), !diagnosticActive, !pauseRequested, !ambientEnabled else {
            throw JotError.message("The microphone cannot start for dictation right now.")
        }
        guard await requestMic() else { throw JotError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), !pauseRequested, !ambientEnabled, !Task.isCancelled else { return }
        guard try await capture.startRetrying(shouldContinue: { lifecycle.acceptsWork(token) && !pauseRequested && !Task.isCancelled }) else { return }
        // Resume during a retry started listening in its own session with audio; the hold runs inside that one.
        guard !ambientEnabled else { return }
        lastAudioAt = dependencies.now()
        guard !Task.isCancelled else { capture.stop(); return }
        // No audio file: a dictation of one voice needs no speaker pass.
        timeline.beginSession(at: dependencies.now(), withAudio: false)
        ambientEnabled = true; updateKeepAwakeAssertion(); scheduleTimer()
        if !switchingInput { livePresentationRevision &+= 1 }
        recordEvent(.started, "Microphone started for a held dictation while paused.")
    }

    /// Ends a hold-only capture: the microphone stops, the hold's session closes, and Jot is paused again. If listening was
    /// requested meanwhile, the microphone stays on and the session simply continues. Called by `pausedHold` after it has
    /// cleared its own state. After an automatic pause, the kept listening intent still waits for Resume.
    private func stopHoldCapture() {
        let keepListening = ambientRequested && listeningRequestedDuringHold
        listeningRequestedDuringHold = false
        guard !keepListening, ambientEnabled || capture.running else { return }
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
        let now = dependencies.now()
        if now.timeIntervalSince(lastCapabilityCheckTime) >= 60 { refreshCapabilities() }
        if now.timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = now
            resourceReadout.snapshot = readoutSampler.sample()
            let queued = transcriber.queuedAudioSeconds
            if transcriber.queuedSeconds != queued { transcriber.queuedSeconds = queued }
            if !pauseRequested, ambientEnabled || dictation.isActive, let lastAudioAt, now.timeIntervalSince(lastAudioAt) > 4 {
                recordEvent(.inputStalled, "No microphone samples for more than four seconds."); pause(automatic: true); post(.microphoneStopped, "Microphone stopped delivering audio. Resume to reconnect; a capture gap occurred.")
            }
            if !pauseRequested, ambientEnabled, !dictation.isActive, !dictation.isPending,
               SessionSplit.shouldStart(silenceMinutes: newSessionAfterSilence,
                silenceSeconds: now.timeIntervalSince(timeline.lastAmbientRowAt ?? timeline.sessionStarted),
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

    func shutdown() {
        cleanup.shutdown()
        if ambientEnabled { recordEvent(.stopped, "Application quit; capture ended.") }
        inputChange?.cancel(); updateHandoff.cancelRecovery()
        modelCheck?.cancel(); preparation?.cancel(); transcriber.cancel(); diagnostic?.cancel(); pausing?.cancel(); unloading?.cancel(); pausedHold.cancelStart()
        suggestions.dismiss(action: .serviceStopped)
        timer?.invalidate(); dictation.releaseFieldEffects(); input.disable(); capture.stop(); updateKeepAwakeAssertion(); server?.stop()
        capture.stopWatching()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    func updateKeepAwakeAssertion() {
        keepAwake.setActive(keepMacAwakeWhileListening && ambientEnabled && capture.running)
    }
}
