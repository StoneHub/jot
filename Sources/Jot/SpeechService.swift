import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import FluidAudio

/// The raw values are what `jot status` reports under "models".
enum ModelState: String { case notLoaded = "not loaded", preparing, ready, failed, unloading, unloaded }

/// The raw values are stored in the capture_events table and shown in History.
enum CaptureEventKind: String {
    case started, paused, stopped, sleep
    case ambientOff = "ambient_off", deviceChange = "device_change", inputStalled = "input_stalled"
    case audioGap = "audio_gap", audioDiscarded = "audio_discarded", processingError = "processing_error"
    case speakerPass = "speaker_pass", sessionSplit = "session_split"
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
    lazy var library = SessionLibrary(host: self)
    lazy var speakers = SpeakerRecognizer(pass: pipeline.speakerPass, host: self)
    lazy var dictation = DictationCoordinator(host: self)
    lazy var timeline = ListeningTimeline(host: self)
    lazy var cleanup = LiveCleanup(host: self)
    private var relays: [AnyCancellable] = []

    init(dependencies: SpeechServiceDependencies = .live) {
        self.dependencies = dependencies
        capture = CaptureController(microphone: dependencies.makeMicrophone(), retry: dependencies.microphoneRetry)
        capture.onNotice = { [weak self] in self?.notice = $0 }
        // The screens observe the service; a change inside an owned object must reach them the same way.
        for child in [capture.objectWillChange.eraseToAnyPublisher(), library.objectWillChange.eraseToAnyPublisher(), speakers.objectWillChange.eraseToAnyPublisher(), timeline.objectWillChange.eraseToAnyPublisher(), cleanup.objectWillChange.eraseToAnyPublisher()] {
            relays.append(child.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }
    @Published var lifecycle = ServiceLifecycle()
    @Published var fnRequested = UserDefaults.standard.bool(forKey: JotDefaultsKey.fnRequested)
    @Published private(set) var shortcut = ShortcutPreferences().load()
    var canChangeShortcut: Bool { !dictation.isActive && !dictation.isPending }
    var canChangeInput: Bool { !capture.running && !dictation.isPending && !diagnosticActive }
    /// Replacing the app must not interrupt capture, a pending dictation, inference, or model setup.
    var canInstallUpdate: Bool { canChangeInput && processing == nil && !preparing && !cleanup.isRunning }
    @Published var highlightTargetField = UserDefaults.standard.object(forKey: JotDefaultsKey.highlightTargetField) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(highlightTargetField, forKey: JotDefaultsKey.highlightTargetField)
            if !highlightTargetField { dictation.hideHighlight() }
        }
    }
    @Published var muteSpeakersDuringDictation = UserDefaults.standard.object(forKey: JotDefaultsKey.muteSpeakersDuringDictation) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muteSpeakersDuringDictation, forKey: JotDefaultsKey.muteSpeakersDuringDictation)
            if !muteSpeakersDuringDictation { dictation.endSpeakerMute() }
        }
    }
    @Published var keepMacAwakeWhileListening = UserDefaults.standard.bool(forKey: JotDefaultsKey.keepMacAwakeWhileListening) {
        didSet {
            UserDefaults.standard.set(keepMacAwakeWhileListening, forKey: JotDefaultsKey.keepMacAwakeWhileListening)
            updateKeepAwakeAssertion()
        }
    }
    /// Minutes of quiet that end an ambient session; 0 keeps one session until capture stops. A named meeting never splits.
    @Published var newSessionAfterSilence = UserDefaults.standard.object(forKey: JotDefaultsKey.newSessionAfterSilence) as? Int ?? SessionSplit.defaultMinutes {
        didSet { UserDefaults.standard.set(newSessionAfterSilence, forKey: JotDefaultsKey.newSessionAfterSilence) }
    }
    /// Off means no audio reaches disk and no speaker pass runs. Switching off mid-session deletes that session's file; switching on waits for the next session, since a file that starts mid-session would misplace every segment.
    @Published var keepAudioForSpeakerPass = UserDefaults.standard.object(forKey: JotDefaultsKey.keepAudioForSpeakerPass) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAudioForSpeakerPass, forKey: JotDefaultsKey.keepAudioForSpeakerPass)
            if !keepAudioForSpeakerPass { timeline.discardSessionAudio() }
        }
    }

    @Published var cleanUpTranscriptions = UserDefaults.standard.object(forKey: JotDefaultsKey.cleanUpTranscriptions) as? Bool ?? true {
        didSet { UserDefaults.standard.set(cleanUpTranscriptions, forKey: JotDefaultsKey.cleanUpTranscriptions) }
    }
    @Published var cleanUpDictation = UserDefaults.standard.bool(forKey: JotDefaultsKey.cleanUpDictation) {
        didSet { UserDefaults.standard.set(cleanUpDictation, forKey: JotDefaultsKey.cleanUpDictation) }
    }
    @Published var recoveryLookbackSeconds = UserDefaults.standard.object(forKey: JotDefaultsKey.recoveryLookbackSeconds) as? Int ?? 120 {
        didSet {
            let bounded = min(600, max(15, recoveryLookbackSeconds))
            if bounded != recoveryLookbackSeconds { recoveryLookbackSeconds = bounded; return }
            UserDefaults.standard.set(bounded, forKey: JotDefaultsKey.recoveryLookbackSeconds)
        }
    }
    @Published var recoveryNotice = ""
    @Published private(set) var cleanupAvailability = TranscriptCleanup.availability

    func setShortcutRecording(_ active: Bool) { input.isRecordingShortcut = active }

    func setShortcut(_ value: DictationShortcut) throws {
        guard canChangeShortcut else { throw JotError.message("Finish dictation before changing its shortcut.") }
        try ShortcutPreferences().save(value)
        shortcut = value
        input.shortcut = value
    }

    @Published var ambientRequested = false
    @Published private(set) var ambientEnabled = false
    @Published var mode = "paused"
    @Published var modelState = ModelState.notLoaded
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
    @Published var tuning = TranscriptionTuning() {
        didSet {
            if let data = try? JSONEncoder().encode(tuning.bounded) { UserDefaults.standard.set(data, forKey: JotDefaultsKey.transcriptionTuning) }
            library.refreshHistory()
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
    @Published var resources = ResourceSnapshot()
    #if DEBUG
    var diagnostics = PerformanceDiagnostics(build: .debug)
    #else
    var diagnostics = PerformanceDiagnostics(build: .release)
    #endif
    private let diagnosticsBegan = ProcessInfo.processInfo.systemUptime
    private var inFlightAudioSeconds = 0.0

    /// Records CPU and memory for `jot diagnostics`. The window's readout comes from the tick, with a sampler of its own.
    func samplePerformance() {
        let sample = sampler.sample()
        guard sample.valid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: sample.physicalFootprintMiB,
            residentMiB: sample.residentMiB, cpuPercent: sample.processCPUPercent,
            droppedAudioSeconds: droppedSeconds, bufferedAudioSeconds: AudioClock.seconds(samples: capture.bufferedSampleCount + timeline.bufferedSampleCount) + inFlightAudioSeconds,
            queuedAudioSeconds: jobs.reduce(0) { $0 + AudioClock.seconds(samples: $1.samples.count) }, loadedHistoryRows: history.count,
            modelsReady: modelState == .ready, ambientEnabled: ambientEnabled, dictationActive: dictation.isActive,
            inferenceRunning: processing != nil))
    }

    func markPerformance(_ kind: PerformanceEventKind) {
        samplePerformance()
        diagnostics.mark(kind, at: ProcessInfo.processInfo.systemUptime - diagnosticsBegan)
    }

    @Published var level: Float = 0
    @Published var fnEnabled = false
    @Published var droppedSeconds = 0.0
    @Published var lagSeconds = 0.0
    @Published var lastInferenceSeconds = 0.0
    @Published var processedAudioSeconds = 0.0
    @Published var lastAudioAt: Date?
    @Published var lastTranscriptAt: Date?
    @Published var queuedSeconds = 0.0
    private(set) var preparing = false
    let pipeline = SpeechPipeline()
    private let sampler = ResourceSampler()
    /// A sampler measures CPU since its previous sample, and `sampler` also samples when a recognition finishes. Sharing it would leave each recognition's CPU out of the next readout, so the readout has its own, sampled only at launch and by the tick.
    private let readoutSampler = ResourceSampler()
    private let keepAwake = KeepAwakeAssertion()
    private var server: LocalServiceServer?
    private var timer: Timer?
    var diagnosticActive = false
    private var preparation: Task<Void, Never>?
    private var pausing: Task<Void, Never>?
    private var sleepResume = SleepResumePolicy()
    var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    private var completedOffsets: [String: Double] = [:]
    private(set) var recognitionFailures = 0
    private(set) var pauseRequested = false
    var jobs: [AudioJob] = []
    var processing: Task<Void, Never>?
    private var processingJob: AudioJob?
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.beginDictation() }, onStop: { [weak self] in self?.endDictation() })
        result.shortcut = shortcut
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
        result.onRecover = { [weak self] in self?.recoverRecentDictation() }
        result.onDiscardTap = { [weak self] in self?.cancelTapDictation() }
        return result
    }()

    func launch() {
        markPerformance(.launch)
        resources = readoutSampler.sample()
        capture.watchDevices()
        do { vocabulary = try vocabularyPreferences.load() }
        catch { vocabularyLoadError = "Could not load vocabulary. Saved entries were preserved. " + error.localizedDescription }
        do {
            store = try TranscriptStore()
            try store?.finalizeInterruptedDictationAttempts()
            speakerStore = try SpeakerPassStore()
            peopleStore = try PeopleStore(); refreshPeople()
            let service = LocalServiceServer { [weak self] data in
                guard let self else { return Data("{\"ok\":false,\"error\":\"Service unavailable\"}".utf8) }
                return await self.handle(data)
            }
            try service.start(); server = service
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.transcriptionTuning),
               let saved = try? JSONDecoder().decode(TranscriptionTuning.self, from: data) { tuning = saved.bounded }
            refreshRecent(); refreshSessions()
            if let attempt = try store?.latestRecoverableDictationAttempt() {
                recoveryNotice = attempt.hasGap
                    ? "Partial dictation was saved. Review it in Sessions; recovery can insert the recognized portion."
                    : "Saved dictation is ready to retry in the current text field."
            }
            for stale in SessionAudioFile.discardStale(except: sessionID) { recordEvent(.audioDiscarded, "Session audio left by an earlier run was deleted.", session: stale) }
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.modelUpdateChecks),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            if UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared), !UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused) {
                ambientRequested = true
                prepare()
            }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
        promptForPermissionsAtLaunch()
        scheduleTimer()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleepResume.willSleep(ambientRunning: self.ambientEnabled, keepAwake: self.keepMacAwakeWhileListening)
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

    var isPaused: Bool { pauseRequested || lifecycle.phase == .paused || lifecycle.phase == .pausing || lifecycle.phase == .failed }
    var isTransitioning: Bool { pauseRequested || lifecycle.phase == .starting || lifecycle.phase == .pausing }
    var keepAwakeActive: Bool { keepAwake.isActive }

    private func resumeAfterSleepIfReady() {
        guard sleepResume.takeResume(phase: lifecycle.phase) else { return }
        guard ambientRequested else { return }
        refreshInputDevices()
        prepare()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = lifecycle.phase == .ready ? 0.2 : 5.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval / 5
    }

    func updateMode() {
        switch lifecycle.phase {
        case .ready: mode = dictation.isActive ? "dictation" : (ambientEnabled ? "ambient" : "ready")
        default: mode = lifecycle.phase.rawValue
        }
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
        preparing = true; modelState = .preparing; updateMode()
        markPerformance(.resume); markPerformance(.modelLoadStarted)
        notice = "Loading models…"
        preparation = Task {
            do {
                try await dependencies.prepareModels(pipeline)
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                modelState = .ready
                markPerformance(.modelsReady)
                UserDefaults.standard.set(true, forKey: JotDefaultsKey.modelsPrepared)
                cachedModelBytes = ModelCache.bytesOnDisk()
                if fnRequested { await enableFn() }
                try await activateAmbient(); try continueMeeting()
                if lifecycle.acceptsWork(token) { notice = "" }
            } catch {
                if lifecycle.finishStart(token, succeeded: false) {
                    modelState = .failed; notice = error.localizedDescription
                    await dependencies.unloadModels(pipeline)
                } else if lifecycle.acceptsWork(token) { notice = error.localizedDescription }
            }
            preparing = false; preparation = nil; updateMode(); scheduleTimer()
        }
    }

    /// Models are loaded but the microphone never started, so Resume has nothing to reload and only the capture needs another try.
    var microphoneOff: Bool { lifecycle.phase == .ready && !ambientEnabled && !pauseRequested && !dictation.isActive }

    private func restartMicrophone() {
        preparation = Task {
            do { try await activateAmbient(); try continueMeeting() }
            catch { notice = error.localizedDescription }
            preparation = nil; updateMode(); scheduleTimer()
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

    func refreshPermissions() {
        micPermission = dependencies.microphoneAuthorization()
        accessibilityGranted = DictationInput.accessibilityGranted
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
        if !fnEnabled { notice = "Enable Accessibility access in System Settings, then switch dictation on again." }
    }

    func disableFn() {
        fnRequested = false; UserDefaults.standard.set(false, forKey: JotDefaultsKey.fnRequested)
        if dictation.isActive { endDictation() }
        input.disable(); fnEnabled = false
    }

    func setAmbient(_ enabled: Bool) async {
        if enabled {
            ambientRequested = true
            do { try await startAmbient() }
            catch { notice = error.localizedDescription }
        } else {
            pause()
        }
    }

    // MARK: Sessions and meetings

    /// A meeting is ambient capture with a name, and an export when it ends.
    func startMeeting(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { notice = "Give the meeting a name first."; return }
        do {
            try await startAmbient()
            guard ambientEnabled else { throw JotError.message("Ambient capture did not start.") }
            meetingTitle = trimmed
            try store?.setTitle(sessionID: sessionID, title: trimmed)
            refreshSessions()
        } catch { meetingTitle = nil; notice = error.localizedDescription }
    }

    /// Renames the running meeting: the name goes on its session now and on any continuation after an automatic pause.
    func renameMeeting(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meetingTitle != nil, !trimmed.isEmpty, let id = activeSessionID else { return }
        meetingTitle = trimmed; renameSession(id, title: trimmed)
    }

    /// Names any session from the socket. Naming the running meeting's session renames the meeting too, so the Live chip and a continuation after an automatic pause use the new name.
    func setSessionTitle(_ id: String, title: String) throws {
        try store?.setTitle(sessionID: id, title: title); refreshSessions()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle != nil, id == activeSessionID, !trimmed.isEmpty { meetingTitle = trimmed }
    }

    /// A meeting kept through an automatic pause records on into a new session under the same name. The earlier part stays in Sessions, and TranscriptExport.write adds " (2)" to a duplicate file name.
    private func continueMeeting() throws {
        guard let meetingTitle, ambientEnabled else { return }
        try store?.setTitle(sessionID: sessionID, title: meetingTitle); refreshSessions()
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
        let id = sessionID
        let generation = lifecycle.generation
        if ambientEnabled { drainAudio(); timeline.flushAmbient(final: true) }
        let throughOffset = ambientOffset
        timeline.endSessionAudio(runPass: true)
        meetingTitle = nil
        if ambientEnabled {
            timeline.beginSession(at: dependencies.now())
            recordEvent(.started, "Listening continued in a fresh session after meeting export.")
            kickWorker()
        }
        if lifecycle.acceptsWork(generation) {
            await waitUntilProcessed(sessionID: id, through: throughOffset)
            if !lifecycle.acceptsWork(generation) {
                notice = "Meeting export interrupted. Saved transcripts remain in Sessions; no file was exported."
                return nil
            }
        }
        refreshSessions()
        // A meeting with nothing transcribed ends quietly; there is no file to show.
        guard (try? store?.session(id: id).isEmpty) == false else { return nil }
        do {
            let url = try exportSession(id)
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
        ambientEnabled = true; updateKeepAwakeAssertion(); updateMode()
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
        if dictation.isActive { endDictation() }
        let loadingTask = preparation, fileTask = diagnostic
        loadingTask?.cancel(); fileTask?.cancel()
        notice = jobs.isEmpty && processing == nil ? "Releasing models…" : "Saving captured speech before Pause…"
        pausing = Task {
            await loadingTask?.value
            _ = try? await fileTask?.value
            while processing != nil || !jobs.isEmpty {
                kickWorker()
                try? await Task.sleep(for: .milliseconds(20))
            }
            await dictation.waitForRecovery()
            guard let token = lifecycle.beginPause() else {
                pauseRequested = false; pausing = nil; return
            }
            ambientEnabled = false; level = 0; queuedSeconds = 0
            // Optional text-only cleanup may finish after capture/models stop.
            // Original recognition is already durable; no microphone is retained.
            modelState = .unloading; updateMode(); notice = "Releasing models…"; scheduleTimer()
            await dependencies.unloadModels(pipeline)
            if lifecycle.finishPause(token) {
                modelState = .unloaded; preparing = false; preparation = nil; updateMode()
                notice = outcome.endedMeeting ? "Meeting stopped. Its transcript is in Sessions." : ""
                markPerformance(.modelsUnloaded); scheduleTimer()
            }
            pauseRequested = false; pausing = nil
            resumeAfterSleepIfReady()
        }
    }

    func stop() { ambientRequested = false; pause() }

    private func tick() {
        if lifecycle.phase == .ready { drainAudio() }
        tickCount += 1
        if dependencies.now().timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = dependencies.now(); refreshPermissions()
            resources = readoutSampler.sample()
            cleanupAvailability = TranscriptCleanup.availability
            queuedSeconds = jobs.reduce(0) { $0 + AudioClock.seconds(samples: $1.samples.count) }
            if !pauseRequested, ambientEnabled || dictation.isActive, let lastAudioAt, dependencies.now().timeIntervalSince(lastAudioAt) > 4 {
                recordEvent(.inputStalled, "No microphone samples for more than four seconds."); pause(automatic: true); notice = "Microphone stopped delivering audio. Resume to reconnect; a capture gap occurred."
            }
            if !pauseRequested, ambientEnabled, !dictation.isActive, !dictation.isPending,
               SessionSplit.shouldStart(silenceMinutes: newSessionAfterSilence,
                silenceSeconds: dependencies.now().timeIntervalSince(timeline.lastAmbientRowAt ?? sessionStarted),
                isMeeting: meetingTitle != nil, workPending: !jobs.isEmpty || processing != nil) { timeline.rotateSession() }
        }
        kickWorker()
    }

    func drainAudio() {
        let packet = capture.drain()
        timeline.ingestAudio(samples: packet.samples, dropped: packet.dropped, lastAudio: packet.lastAudio, rms: packet.rms)
    }

    /// Integration/performance seam: the same ingestion and scheduling path used by
    /// microphone drains, with inference and delivery supplied through dependencies.
    func ingestRecoveryVerification(samples: [Float], rms: Float = 0.01, at date: Date = Date()) {
        timeline.ingestAudio(samples: samples, dropped: 0, lastAudio: date, rms: rms)
        kickWorker()
    }

    func beginRecoveryVerification(store: TranscriptStore, startedAt: Date = Date()) {
        if let token = lifecycle.beginStart() { _ = lifecycle.finishStart(token, succeeded: true) }
        self.store = store
        modelState = .ready; ambientRequested = true; ambientEnabled = true
        timeline.beginSession(at: startedAt, withAudio: false)
        updateMode()
    }

    func flushRecoveryVerification() {
        timeline.flushAmbient(final: true)
        kickWorker()
    }

    /// Runs one timer tick on the injected clock, so the harness reaches the quiet split and the stalled-microphone pause without starting the timer.
    func tickRecoveryVerification() { tick() }

    /// The harness waits for Resume, or a microphone restart, to settle.
    func waitForPreparation() async {
        if let preparation { await preparation.value }
    }

    func waitForRecoveryVerification() async {
        while processing != nil || !jobs.isEmpty || dictation.isBusy || cleanup.isRunning {
            kickWorker()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func kickWorker() {
        guard lifecycle.phase == .ready, processing == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        processingJob = job
        let generation = lifecycle.generation
        let began = ProcessInfo.processInfo.systemUptime
        let waitSeconds = max(0, began - job.submittedUptime)
        inFlightAudioSeconds = AudioClock.seconds(samples: job.samples.count)
        processing = Task {
            var outcome = PerformanceJob.Outcome.completed
            var inferenceSeconds: Double?
            do {
                let output = try await dependencies.infer(pipeline, job, tuning)
                try Task.checkCancellation()
                guard lifecycle.acceptsWork(generation) else { throw CancellationError() }
                inferenceSeconds = output.processingSeconds
                outcome = output.text.isEmpty ? .noSpeech : .completed
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += AudioClock.seconds(samples: job.samples.count)
                lagSeconds = max(0, dependencies.now().timeIntervalSince(job.startedAt) - job.offset - AudioClock.seconds(samples: job.samples.count))
                // Persist recognition before awaiting optional cleanup. Capture keeps draining while we await.
                let sources = output.transcripts
                if (job.mode == .ambient || job.submittedUptime > library.historyClearedAt) && !sessionIsDeleted(job.sessionID) {
                    for transcript in sources { try store?.append(transcript) }
                    // Word evidence is kept in the session's clock so a saved session can be regrouped later. Dictation rows keep none.
                    let words = sources.flatMap { transcript in
                        (output.wordsByTranscript[transcript.id] ?? []).enumerated().map { position, word in
                            StoredWord(transcriptID: transcript.id, position: position, word: word.text, startSeconds: job.offset + word.start, endSeconds: job.offset + word.end, probabilities: word.probabilities)
                        }
                    }
                    try store?.appendWords(words)
                    if !sources.isEmpty {
                        lastTranscriptAt = dependencies.now()
                        if job.mode == .ambient, job.sessionID == sessionID { timeline.lastAmbientRowAt = dependencies.now() }
                        // Live must see recognition before the model's cleanup suspension.
                        refreshRecent(); refreshSessions()
                    }
                }
                cleanup.scheduleCleanup(sources: sources, final: job.isFinal)
                dictation.updateAttemptText(for: job)
            } catch {
                outcome = error is CancellationError ? .cancelled : .failed
                recognitionFailures += 1
                dictation.noteRecognitionFailure(for: job)
                if !(error is CancellationError) { recordEvent(.processingError, error.localizedDescription, session: job.sessionID) }
                if lifecycle.acceptsWork(generation), job.mode != .dictation || job.ticket == dictation.ticket {
                    notice = "\(job.mode.rawValue.capitalized): \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            diagnostics.record(.init(elapsedSeconds: ProcessInfo.processInfo.systemUptime - diagnosticsBegan,
                mode: job.mode == .dictation ? .dictation : .ambient, outcome: outcome,
                audioSeconds: AudioClock.seconds(samples: job.samples.count), queueWaitSeconds: waitSeconds,
                inferenceSeconds: inferenceSeconds, completionSeconds: max(0, ProcessInfo.processInfo.systemUptime - job.submittedUptime),
                cleanupSeconds: nil, deliverySeconds: nil))
            completedOffsets[job.sessionID] = max(completedOffsets[job.sessionID] ?? 0,
                job.offset + AudioClock.seconds(samples: job.samples.count))
            inFlightAudioSeconds = 0
            processingJob = nil
            processing = nil
            samplePerformance()
            kickWorker()
        }
    }

    func waitUntilProcessed(sessionID: String, through offset: Double) async {
        let barrierTickets = Set(jobs.filter { $0.sessionID == sessionID && $0.offset <= offset }.map(\.ticket)
            + (processingJob.map { $0.sessionID == sessionID ? [$0.ticket] : [] } ?? []))
        while !Task.isCancelled,
              jobs.contains(where: { barrierTickets.contains($0.ticket) }) ||
              processingJob.map({ barrierTickets.contains($0.ticket) }) == true {
            kickWorker()
            // A sub-minimum tail has no inference job. Everything schedulable is done.
            if processing == nil && jobs.allSatisfy({ $0.sessionID != sessionID }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Counts and state only; transcript and field contents never enter diagnostics.
    var recoveryDiagnostics: [String: Any] {
        [
            "lookbackSeconds": recoveryLookbackSeconds,
            "attemptState": dictation.currentAttempt?.state.rawValue ?? "none",
            "attemptPending": dictation.isActive || dictation.isPending,
            "pendingAudioJobs": jobs.count + (processing == nil ? 0 : 1),
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
        case .ambientOff: marker = .ambientStopped
        case .sleep: marker = .sleep
        case .deviceChange: marker = .deviceChange
        case .audioGap: marker = .audioGap
        case .processingError: marker = .processingFailed
        default: marker = nil
        }
        if let marker { markPerformance(marker) }
        do { try store?.appendEvent(CaptureEvent(sessionID: session ?? sessionID, kind: kind.rawValue, detail: detail, durationSeconds: duration)) }
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
        modelCheck?.cancel(); preparation?.cancel(); processing?.cancel(); diagnostic?.cancel(); pausing?.cancel()
        timer?.invalidate(); dictation.releaseFieldEffects(); input.disable(); capture.stop(); updateKeepAwakeAssertion(); server?.stop()
        capture.stopWatching()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    private func updateKeepAwakeAssertion() {
        keepAwake.setActive(keepMacAwakeWhileListening && ambientEnabled && capture.running)
    }
}
