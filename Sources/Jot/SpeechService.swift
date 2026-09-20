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

@MainActor
final class SpeechService: ObservableObject {
    @Published var lifecycle = ServiceLifecycle()
    @Published var fnRequested = UserDefaults.standard.bool(forKey: JotDefaultsKey.fnRequested)
    @Published private(set) var shortcut = ShortcutPreferences().load()
    var canChangeShortcut: Bool { !dictationActive && !dictationPending }
    var canChangeInput: Bool { !capture.running && !dictationPending && !diagnosticActive }
    /// Replacing the app must not interrupt capture, a pending dictation, inference, or model setup.
    var canInstallUpdate: Bool { canChangeInput && processing == nil && !preparing }
    private let speakerMute = DictationSpeakerMute()
    private let highlight = DictationHighlight()
    @Published var highlightTargetField = UserDefaults.standard.object(forKey: JotDefaultsKey.highlightTargetField) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(highlightTargetField, forKey: JotDefaultsKey.highlightTargetField)
            if !highlightTargetField { highlight.hide() }
        }
    }
    @Published var muteSpeakersDuringDictation = UserDefaults.standard.object(forKey: JotDefaultsKey.muteSpeakersDuringDictation) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muteSpeakersDuringDictation, forKey: JotDefaultsKey.muteSpeakersDuringDictation)
            if !muteSpeakersDuringDictation { speakerMute.end() }
        }
    }
    @Published var keepMacAwakeWhileListening = UserDefaults.standard.bool(forKey: JotDefaultsKey.keepMacAwakeWhileListening) {
        didSet {
            UserDefaults.standard.set(keepMacAwakeWhileListening, forKey: JotDefaultsKey.keepMacAwakeWhileListening)
            if !keepMacAwakeWhileListening { sleepResume.cancel() }
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
            if !keepAudioForSpeakerPass { sessionAudio?.discard(); sessionAudio = nil }
        }
    }

    @Published var cleanUpTranscriptions = UserDefaults.standard.object(forKey: JotDefaultsKey.cleanUpTranscriptions) as? Bool ?? true {
        didSet { UserDefaults.standard.set(cleanUpTranscriptions, forKey: JotDefaultsKey.cleanUpTranscriptions) }
    }
    @Published var cleanUpDictation = UserDefaults.standard.bool(forKey: JotDefaultsKey.cleanUpDictation) {
        didSet { UserDefaults.standard.set(cleanUpDictation, forKey: JotDefaultsKey.cleanUpDictation) }
    }
    @Published private(set) var cleanupAvailability = TranscriptCleanup.availability
    private let transcriptCleanup = TranscriptCleanup()

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
    @Published var recent: [Transcript] = []
    /// Content changes include cleanup replacements that leave row counts unchanged.
    @Published private(set) var transcriptRevision = 0
    @Published var history: [Transcript] = []
    @Published var events: [CaptureEvent] = []
    @Published var hasMoreHistory = false
    /// Every saved dictation row, for the Dictations count in the sidebar.
    @Published private(set) var dictationCount = 0
    @Published var modelUpdates = ModelUpdate.defaults
    @Published var checkingModels = false
    @Published var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputUID = UserDefaults.standard.string(forKey: JotDefaultsKey.selectedInputUID) ?? ""
    @Published private(set) var selectedInputName = UserDefaults.standard.string(forKey: JotDefaultsKey.selectedInputName) ?? "Saved microphone"
    /// True while the saved microphone is unplugged; capture then runs on System Default and the choice is kept.
    @Published private(set) var selectedInputMissing = false
    @Published private(set) var systemDefaultInputName = "System Default"
    private var inputWatcher: AudioInputDeviceWatcher?
    /// Picker rows: every connected input, plus the saved one marked not connected so the selection always matches a tag.
    var inputRows: [AudioInputDevice] {
        guard selectedInputMissing else { return inputDevices }
        return inputDevices + [AudioInputDevice(id: selectedInputUID, name: "\(selectedInputName) (not connected)")]
    }
    @Published var accessibilityGranted = DictationInput.accessibilityGranted
    @Published private(set) var cachedModelBytes = ModelCache.bytesOnDisk()
    /// Set when a resume would download models that are not cached yet. The view asks before any download starts.
    @Published var downloadPrompt: Int64?
    @Published private(set) var sessions: [TranscriptSession] = []
    /// Title of the meeting being recorded; nil when ambient is off or was started without a name.
    @Published private(set) var meetingTitle: String?
    @Published private(set) var activeSessionID: String?
    @Published private(set) var lastExport: URL?
    @Published var tuning = TranscriptionTuning() {
        didSet {
            if let data = try? JSONEncoder().encode(tuning.bounded) { UserDefaults.standard.set(data, forKey: JotDefaultsKey.transcriptionTuning) }
            refreshHistory()
        }
    }
    @Published private(set) var vocabulary = PersonalVocabulary()
    @Published private(set) var vocabularyLoadError: String?
    private let vocabularyPreferences = VocabularyPreferences()
    private var dictationVocabulary = PersonalVocabulary()

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
    @Published private(set) var historyRevision = 0
    private var historySources: [String: [String]] = [:]
    private var historyClearedAt: TimeInterval = -1
    private var deletedSessions = Set<String>()
    private var historyQuery = ""
    private var historyLimit = 50
    @Published var resources = ResourceSnapshot()
    #if DEBUG
    var diagnostics = PerformanceDiagnostics(build: .debug)
    #else
    var diagnostics = PerformanceDiagnostics(build: .release)
    #endif
    private let diagnosticsBegan = ProcessInfo.processInfo.systemUptime
    /// Shorter audio is dropped: recognition on it is noise.
    private static let minimumJobSamples = AudioClock.samples(seconds: 0.2)
    private static let ambientBreakSamples = AudioClock.samples(seconds: 2)
    private static let ambientBlockSamples = AudioClock.samples(seconds: 20)
    private static let dictationLimit = AudioClock.samples(seconds: 60)
    private var inFlightAudioSeconds = 0.0

    func samplePerformance() {
        resources = sampler.sample()
        guard resources.valid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: resources.physicalFootprintMiB,
            residentMiB: resources.residentMiB, cpuPercent: resources.processCPUPercent,
            droppedAudioSeconds: droppedSeconds, bufferedAudioSeconds: AudioClock.seconds(samples: capture.bufferedSampleCount + ambient.count + dictation.count) + inFlightAudioSeconds,
            queuedAudioSeconds: jobs.reduce(0) { $0 + AudioClock.seconds(samples: $1.samples.count) }, loadedHistoryRows: history.count,
            modelsReady: modelState == .ready, ambientEnabled: ambientEnabled, dictationActive: dictationActive,
            inferenceRunning: processing != nil))
    }

    private func markPerformance(_ kind: PerformanceEventKind) {
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
    let capture = MicrophoneCapture()
    let pipeline = SpeechPipeline()
    private let sampler = ResourceSampler()
    private let keepAwake = KeepAwakeAssertion()
    var store: TranscriptStore?
    var speakerStore: SpeakerPassStore?
    var peopleStore: PeopleStore?
    /// Voices Jot remembers, for the People screen and for naming matching speakers after a pass.
    @Published private(set) var people: [Person] = []
    private var server: LocalServiceServer?
    private var timer: Timer?
    var diagnosticActive = false
    private var preparation: Task<Void, Never>?
    private var pausing: Task<Void, Never>?
    private var sleepResume = SleepResumePolicy()
    var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    var sessionID = UUID().uuidString
    /// Wall-clock start of the current ambient session; Live counts elapsed time from it.
    private(set) var sessionStarted = Date()
    /// When this session last produced a row, so a quiet stretch can be measured.
    private var lastAmbientRowAt: Date?
    private var ambientOffset = 0.0
    private var ambient: [Float] = []
    /// The session's audio on disk for the speaker pass; nil while no ambient session runs.
    private var sessionAudio: SessionAudioFile?
    @Published private(set) var speakerPassRunning = false
    /// Passes run one at a time in session order; a pass survives a pause and finishes on its own.
    private var speakerPassQueue: Task<Void, Never>?
    private var silentSeconds = 0.0
    private var dictation: [Float] = []
    private var dictationActive = false
    private var dictationPending = false
    private var dictationTicket = UUID()
    private var dictationStarted = Date()
    var jobs: [AudioJob] = []
    var processing: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.beginDictation() }, onStop: { [weak self] in self?.endDictation() })
        result.shortcut = shortcut
        result.canStart = { [weak self] in
            guard let self else { return false }
            return self.lifecycle.phase == .ready && self.modelState == .ready && !self.dictationPending && !self.dictationActive && !self.diagnosticActive
        }
        result.onError = { [weak self] error in
            self?.notice = error.localizedDescription
            self?.cancelDictation()
        }
        return result
    }()

    func launch() {
        markPerformance(.launch)
        refreshInputDevices()
        inputWatcher = AudioInputDeviceWatcher { [weak self] in self?.refreshInputDevices() }
        do { vocabulary = try vocabularyPreferences.load() }
        catch { vocabularyLoadError = "Could not load vocabulary. Saved entries were preserved. " + error.localizedDescription }
        do {
            store = try TranscriptStore()
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
            for stale in SessionAudioFile.discardStale(except: sessionID) { recordEvent(.audioDiscarded, "Session audio left by an earlier run was deleted.", session: stale) }
            if let data = UserDefaults.standard.data(forKey: JotDefaultsKey.modelUpdateChecks),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            if UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared), !UserDefaults.standard.bool(forKey: JotDefaultsKey.servicePaused) { prepare() }
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
                guard let self, self.ambientEnabled || self.dictationActive else { return }
                if self.capture.shouldIgnoreConfigurationChange() { return }
                self.recordEvent(.deviceChange, "Audio input configuration changed."); self.pause(automatic: true); self.notice = "Audio input changed. Resume when ready."
            }
        })
    }

    var isPaused: Bool { lifecycle.phase == .paused || lifecycle.phase == .pausing || lifecycle.phase == .failed }
    var isTransitioning: Bool { lifecycle.phase == .starting || lifecycle.phase == .pausing }
    var keepAwakeActive: Bool { keepAwake.isActive }

    private func resumeAfterSleepIfReady() {
        guard sleepResume.takeResume(phase: lifecycle.phase) else { return }
        guard keepMacAwakeWhileListening, ambientRequested else { return }
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

    private func updateMode() {
        switch lifecycle.phase {
        case .ready: mode = dictationActive ? "dictation" : (ambientEnabled ? "ambient" : "ready")
        default: mode = lifecycle.phase.rawValue
        }
    }

    /// Resume. The first resume downloads models, so it asks before spending bandwidth.
    func prepare(confirmingDownload: Bool = false) {
        sleepResume.cancel()
        cachedModelBytes = ModelCache.bytesOnDisk()
        if cachedModelBytes == 0 && !confirmingDownload {
            downloadPrompt = ModelCache.expectedBytes
            return
        }
        downloadPrompt = nil
        guard let token = lifecycle.beginStart() else { return }
        UserDefaults.standard.set(false, forKey: JotDefaultsKey.servicePaused)
        preparing = true; modelState = .preparing; updateMode()
        markPerformance(.resume); markPerformance(.modelLoadStarted)
        notice = "Loading models…"
        preparation = Task {
            do {
                try await pipeline.prepare()
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                modelState = .ready
                markPerformance(.modelsReady)
                UserDefaults.standard.set(true, forKey: JotDefaultsKey.modelsPrepared)
                cachedModelBytes = ModelCache.bytesOnDisk()
                if fnRequested { await enableFn() }
                if ambientRequested { try await activateAmbient(); try continueMeeting() }
                if lifecycle.acceptsWork(token) { notice = "" }
            } catch {
                if lifecycle.finishStart(token, succeeded: false) {
                    modelState = .failed; notice = error.localizedDescription
                    await pipeline.unload()
                } else if lifecycle.acceptsWork(token) { notice = error.localizedDescription }
            }
            preparing = false; preparation = nil; updateMode(); scheduleTimer()
        }
    }

    func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: refreshPermissions(); return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
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
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = DictationInput.accessibilityGranted
    }

    func refreshInputDevices() {
        inputDevices = AudioInputDevice.available()
        systemDefaultInputName = AudioInputDevice.defaultName() ?? "System Default"
        if let saved = inputDevices.first(where: { $0.id == selectedInputUID }), saved.name != selectedInputName {
            selectedInputName = saved.name; UserDefaults.standard.set(saved.name, forKey: JotDefaultsKey.selectedInputName)
        }
        let wasMissing = selectedInputMissing
        let captureUID = MicrophoneSelection.captureUID(saved: selectedInputUID, available: inputDevices.map(\.id))
        selectedInputMissing = !selectedInputUID.isEmpty && captureUID == nil
        if selectedInputMissing && !wasMissing { notice = "\(selectedInputName) is not connected. Using System Default until it returns." }
        if wasMissing && !selectedInputMissing { notice = capture.running ? "\(selectedInputName) is connected again. Jot uses it when capture next starts." : "\(selectedInputName) is connected again." }
        capture.setInputForNextStart(uid: captureUID)
    }

    func setInput(uid: String) {
        guard canChangeInput else { return }
        do {
            try capture.setInput(uid: MicrophoneSelection.captureUID(saved: uid, available: inputDevices.map(\.id)))
            selectedInputUID = uid
            if let device = inputDevices.first(where: { $0.id == uid }) { selectedInputName = device.name }
            selectedInputMissing = !uid.isEmpty && !inputDevices.contains { $0.id == uid }
            if uid.isEmpty { UserDefaults.standard.removeObject(forKey: JotDefaultsKey.selectedInputUID); UserDefaults.standard.removeObject(forKey: JotDefaultsKey.selectedInputName) }
            else { UserDefaults.standard.set(uid, forKey: JotDefaultsKey.selectedInputUID); UserDefaults.standard.set(selectedInputName, forKey: JotDefaultsKey.selectedInputName) }
            notice = ""
        } catch { notice = error.localizedDescription }
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
        cancelDictation(); input.disable(); fnEnabled = false; notice = ""
    }

    func setAmbient(_ enabled: Bool) async {
        if enabled {
            guard lifecycle.phase == .ready else {
                ambientRequested = false
                notice = "Resume Jot before enabling ambient transcription."
                return
            }
            ambientRequested = true
            do { try await activateAmbient() }
            catch { ambientRequested = false; notice = error.localizedDescription }
        } else {
            sleepResume.cancel()
            ambientRequested = false
            guard lifecycle.phase == .ready else { ambientEnabled = false; updateMode(); return }
            if !dictationActive { capture.stop(); updateKeepAwakeAssertion() }
            drainAudio()
            if ambientEnabled { flushAmbient(); recordEvent(.ambientOff, "Ambient transcription switched off."); endSessionAudio(runPass: true) }
            ambientEnabled = false; updateMode(); level = 0; kickWorker()
        }
    }

    // MARK: Sessions and meetings

    func clearHistory() throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        try store.clearHistory()
        historyClearedAt = ProcessInfo.processInfo.systemUptime
        lastExport = nil
        historyLimit = 50
        didDeleteHistory()
        notice = "Dictations cleared. Sessions were kept."
    }

    func canDeleteSession(_ id: String) -> Bool { !(id == activeSessionID && ambientEnabled) }

    func deleteSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before deleting it.") }
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        try store.deleteSession(id: id)
        deletedSessions.insert(id)
        didDeleteHistory()
        notice = "Session deleted."
    }

    /// Rebuilds a saved session's rows from its stored words under the current Tuning: from the speaker pass's segments when the session has them, otherwise from the live probabilities. Cleanup text is not re-run.
    func regroupSession(_ id: String) throws {
        guard canDeleteSession(id) else { throw JotError.message("Stop recording this session before regrouping it.") }
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let words = try store.words(sessionID: id)
        let segments = try speakerStore?.segments(sessionID: id) ?? []
        if segments.isEmpty {
            try store.replaceSession(sessionID: id, words: words, turns: TranscriptGrouping.regroup(words: words, tuning: tuning))
            notice = "Session regrouped with the current tuning."
        } else {
            try store.replaceSession(sessionID: id, words: words, turns: SpeakerPassRelabel.turns(words: words, segments: segments.map { ($0.speakerID, $0.start, $0.end) }, tuning: tuning))
            notice = "Session regrouped from the speaker pass."
        }
        didDeleteHistory()
    }

    func deleteHistoryCard(_ item: Transcript) throws {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        try store.deleteTranscripts(ids: historySources[item.id] ?? [item.id])
        didDeleteHistory()
        notice = "Transcript deleted."
    }

    private func didDeleteHistory() {
        refreshRecent(); refreshSessions()
        historyRevision += 1
    }

    func refreshSessions() {
        do { sessions = try store?.sessions(limit: 200) ?? [] } catch { notice = error.localizedDescription }
    }

    /// Folded and merged rows for reading one session. Stored rows are untouched.
    func sessionParagraphs(_ id: String) -> [Transcript] {
        guard let store else { return [] }
        do { return TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(try store.session(id: id), gap: tuning.bounded.paragraphPause), mergeWithin: tuning.bounded.paragraphPause) }
        catch { notice = error.localizedDescription; return [] }
    }

    /// Rows from any ambient session whose text contains the query, newest first, for the Sessions search.
    func searchSessions(_ query: String) -> [Transcript] {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do { return try store.search(query, mode: "ambient", limit: 50) } catch { notice = error.localizedDescription; return [] }
    }

    func renameSession(_ id: String, title: String) {
        do { try store?.setTitle(sessionID: id, title: title); refreshSessions() }
        catch { notice = error.localizedDescription }
    }

    static var exportDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jot Sessions", isDirectory: true)
    }

    /// The summary and rows an export is built from; an unknown or dictation-only id has neither.
    func exportable(_ id: String) throws -> (session: TranscriptSession, rows: [Transcript]) {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let rows = try store.session(id: id)
        guard !rows.isEmpty, let session = try store.sessionSummary(id: id) else {
            throw JotError.message("Nothing was transcribed in this session, so there is no file to save.")
        }
        return (session, rows)
    }

    /// Writes one session as Markdown into ~/Documents/Jot Sessions and returns the file.
    @discardableResult
    func exportSession(_ id: String) throws -> URL {
        let (session, rows) = try exportable(id)
        let url = try TranscriptExport.write(session: session, rows: rows, directory: Self.exportDirectory)
        lastExport = url
        return url
    }

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

    /// A meeting kept through an automatic pause records on into a new session under the same name. The earlier part stays in Sessions, and TranscriptExport.write adds " (2)" to a duplicate file name.
    private func continueMeeting() throws {
        guard let meetingTitle, ambientEnabled else { return }
        try store?.setTitle(sessionID: sessionID, title: meetingTitle); refreshSessions()
    }

    /// Stops capture, waits for the queued audio to finish, then writes the file and shows it in Finder.
    @discardableResult
    func endMeeting() async -> URL? {
        lastExport = nil
        let id = sessionID
        let generation = lifecycle.generation
        await setAmbient(false)
        // Ending while paused skips the wait: the pause already discarded any unfinished audio, so the saved rows are all there is.
        if lifecycle.acceptsWork(generation) {
            do {
                try await MeetingExportWait.wait(
                    isValid: { self.lifecycle.acceptsWork(generation) && self.sessionID == id },
                    isComplete: {
                        self.kickWorker()
                        return self.jobs.allSatisfy { $0.mode != .ambient } && self.processing == nil
                    })
            } catch {
                notice = "Meeting export interrupted. Saved transcripts remain in Sessions; no file was exported."
                return nil
            }
        }
        meetingTitle = nil
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
        guard lifecycle.acceptsWork(token), !diagnosticActive else { throw JotError.message("Resume the service before listening.") }
        guard await requestMic() else { throw JotError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), ambientRequested else { return }
        guard !ambientEnabled else { return }
        if !capture.running { lastAudioAt = Date() }
        try capture.start()
        sessionID = UUID().uuidString; sessionStarted = Date(); ambientOffset = 0; activeSessionID = sessionID
        ambient = []; silentSeconds = 0; lastAmbientRowAt = nil; ambientEnabled = true; updateKeepAwakeAssertion(); updateMode()
        if keepAudioForSpeakerPass { sessionAudio = SessionAudioFile(sessionID: sessionID) }
        recordEvent(.started, "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        ambientRequested = true
        if lifecycle.phase == .paused || lifecycle.phase == .failed { prepare() }
        if let preparation { await preparation.value }
        guard lifecycle.phase == .ready else { throw JotError.message("The service is not ready. Wait for Pause to finish, then Resume.") }
        try await activateAmbient()
    }

    /// Stop all speech work immediately, then release models when any active prediction returns. Automatic pauses keep the selection and a running meeting for Resume.
    func pause(automatic: Bool = false) {
        if !automatic { sleepResume.cancel() }
        guard let token = lifecycle.beginPause() else { return }
        markPerformance(.pause)
        UserDefaults.standard.set(true, forKey: JotDefaultsKey.servicePaused)
        capture.stop()
        updateKeepAwakeAssertion()
        let packet = capture.drain()
        let discarded = AudioClock.seconds(samples: packet.samples.count + packet.dropped + ambient.count + dictation.count + jobs.reduce(0) { $0 + $1.samples.count })
        if discarded > 0 { recordEvent(.audioDiscarded, "Unfinished audio discarded by Pause.") }
        if ambientEnabled { recordEvent(.paused, "Service paused.") }
        endSessionAudio(runPass: automatic)
        let outcome = PauseOutcome(automatic: automatic, ambientRequested: ambientRequested, meetingTitle: meetingTitle)
        ambientRequested = outcome.ambientRequested; meetingTitle = outcome.meetingTitle; ambientEnabled = false
        cancelDictation(); input.disable(); fnEnabled = false
        ambient.removeAll(keepingCapacity: false); jobs.removeAll(keepingCapacity: false)
        capture.discardBufferedAudio(); queuedSeconds = 0; level = 0
        let loadingTask = preparation, worker = processing, fileTask = diagnostic
        loadingTask?.cancel(); worker?.cancel(); fileTask?.cancel()
        modelState = .unloading; updateMode(); notice = "Releasing models…"
        scheduleTimer()
        pausing = Task {
            await loadingTask?.value
            await worker?.value
            _ = try? await fileTask?.value
            await pipeline.unload()
            if lifecycle.finishPause(token) {
                modelState = .unloaded; preparing = false; preparation = nil; updateMode()
                notice = outcome.endedMeeting ? "Meeting stopped. Its transcript is in Sessions." : ""
                markPerformance(.modelsUnloaded); scheduleTimer()
            }
            pausing = nil
            resumeAfterSleepIfReady()
        }
    }

    func stop() { ambientRequested = false; pause() }

    func beginDictation() {
        guard lifecycle.phase == .ready, modelState == .ready, !dictationPending else { return }
        drainAudio()
        do {
            if !capture.running { lastAudioAt = Date() }
            if muteSpeakersDuringDictation { speakerMute.begin() }
            try capture.start()
            updateKeepAwakeAssertion()
            dictationVocabulary = vocabulary
            dictation = []; dictationStarted = Date(); dictationTicket = UUID(); dictationActive = true
            transcriptCleanup.cancel()
            if highlightTargetField { highlight.show(follow: { [weak self] in self?.input.targetFrame() }) }
            updateMode()
            markPerformance(.dictationStarted)
            notice = "Listening for dictation… release \(shortcut.displayName) to insert."
        } catch { cancelDictation(); notice = error.localizedDescription }
    }

    func endDictation() {
        speakerMute.end(); highlight.hide()
        guard dictationActive else { return }
        if !ambientEnabled { capture.stop(); updateKeepAwakeAssertion() }
        drainAudio()
        guard dictationActive else { return }
        dictationActive = false
        markPerformance(.dictationReleased)
        level = 0
        updateMode()
        guard dictation.count >= Self.minimumJobSamples else { dictation = []; input.discardTarget(); notice = "Too little audio to transcribe."; return }
        dictationPending = true
        let job = AudioJob(sessionID: UUID().uuidString, startedAt: dictationStarted, offset: 0,
            samples: dictation, mode: .dictation, ticket: dictationTicket)
        dictation = []; jobs.insert(job, at: 0); notice = "Transcribing dictation locally…"; kickWorker()
    }

    private func cancelDictation() {
        speakerMute.end(); highlight.hide()
        if dictationActive || dictationPending { markPerformance(.dictationCancelled) }
        input.discardTarget()
        dictationActive = false; dictationPending = false; dictationTicket = UUID(); dictation = []
        jobs.removeAll { $0.mode == .dictation }
        if !ambientEnabled { capture.stop(); updateKeepAwakeAssertion() }
        updateMode()
    }

    private func tick() {
        if lifecycle.phase == .ready { drainAudio() }
        tickCount += 1
        if Date().timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = Date(); refreshPermissions()
            cleanupAvailability = TranscriptCleanup.availability
            queuedSeconds = jobs.reduce(0) { $0 + AudioClock.seconds(samples: $1.samples.count) }
            if ambientEnabled || dictationActive, let lastAudioAt, Date().timeIntervalSince(lastAudioAt) > 4 {
                recordEvent(.inputStalled, "No microphone samples for more than four seconds."); pause(automatic: true); notice = "Microphone stopped delivering audio. Resume to reconnect; a capture gap occurred."
            }
            if ambientEnabled, SessionSplit.shouldStart(silenceMinutes: newSessionAfterSilence,
                silenceSeconds: Date().timeIntervalSince(lastAmbientRowAt ?? sessionStarted),
                isMeeting: meetingTitle != nil, workPending: !jobs.isEmpty || processing != nil) { rotateSession() }
        }
        kickWorker()
    }

    private func drainAudio() {
        let packet = capture.drain()
        guard !packet.samples.isEmpty || packet.dropped > 0 else { return }
        level = packet.rms
        lastAudioAt = packet.lastAudio
        if packet.dropped > 0 {
            if dictationActive { cancelDictation() }
            let lostSeconds = AudioClock.seconds(samples: packet.dropped + ambient.count)
            droppedSeconds += lostSeconds
            recordEvent(.audioGap, "Capture queue overflow discarded audio.", duration: lostSeconds)
            // End attribution continuity rather than silently stitching across lost audio.
            ambientOffset += AudioClock.seconds(samples: ambient.count + packet.dropped); ambient = []
            sessionAudio?.appendSilence(samples: packet.dropped)
            notice = "Audio backlog overflow: a gap was recorded."
        }
        if dictationActive {
            if dictation.count + packet.samples.count <= Self.dictationLimit { dictation.append(contentsOf: packet.samples) }
            else { cancelDictation(); notice = "Dictation exceeded 60 seconds; cancelled without inserting a partial prompt." }
        }
        if ambientEnabled {
            ambient.append(contentsOf: packet.samples)
            sessionAudio?.append(packet.samples)
            silentSeconds = packet.rms < 0.002 ? silentSeconds + AudioClock.seconds(samples: packet.samples.count) : 0
            // Blocks run up to 20 s and only break on a 2 s silence, so most sentences reach the recognizer whole.
            if ambient.count >= Self.ambientBlockSamples || (ambient.count >= Self.ambientBreakSamples && silentSeconds >= max(2, tuning.bounded.paragraphPause)) { flushAmbient() }
        }
    }

    /// The normal end and an automatic pause run the pass, since Resume starts a new session and this one is complete. The Pause button discards the file along with the rest of its unfinished audio.
    /// Capture keeps running; only the session it feeds changes, so the speaker pass and Live both start fresh on the next speech.
    private func rotateSession() {
        let spoken = lastAmbientRowAt != nil
        flushAmbient()
        if spoken { recordEvent(.sessionSplit, "New session started after \(newSessionAfterSilence) minutes of quiet.") }
        endSessionAudio(runPass: spoken)
        sessionID = UUID().uuidString; sessionStarted = Date(); ambientOffset = 0; activeSessionID = sessionID
        ambient = []; silentSeconds = 0; lastAmbientRowAt = nil
        if keepAudioForSpeakerPass { sessionAudio = SessionAudioFile(sessionID: sessionID) }
        refreshSessions()
    }

    private func endSessionAudio(runPass: Bool) {
        guard let file = sessionAudio else { return }
        sessionAudio = nil
        guard runPass else { file.discard(); return }
        let previous = speakerPassQueue
        speakerPassQueue = Task { await previous?.value; await runSpeakerPass(file) }
    }

    /// The pass runs off the main actor; only its outcome lands here. An export that already happened used the live labels; the saved rows are rebuilt from the pass once the session's last audio block is recognized.
    private func runSpeakerPass(_ file: SessionAudioFile) async {
        let id = file.sessionID
        speakerPassRunning = true
        defer { speakerPassRunning = false }
        do {
            guard let audio = try await file.finish() else { return }
            let result = SpeakerPassRelabel.renumbered(try await pipeline.speakerPass.run(url: audio.url))
            try await MeetingExportWait.wait(isValid: { true }, isComplete: { self.jobs.allSatisfy { $0.sessionID != id } && self.processing == nil })
            guard !deletedSessions.contains(id) else { return }
            try speakerStore?.replace(sessionID: id, result: result)
            // The pass is authoritative: a name given to "speaker-2" while the live labels were showing stays on that id, which the pass may have given to another voice. Naming normally happens after the pass anyway.
            var recognized: [String] = []
            if let store, !result.segments.isEmpty, case let words = try store.words(sessionID: id), !words.isEmpty {
                try store.replaceSession(sessionID: id, words: words, turns: SpeakerPassRelabel.turns(words: words, segments: result.segments, tuning: tuning))
                recognized = try recognizeSpeakers(result.speakers, session: id)
                didDeleteHistory()
            }
            let count = result.speakers.count
            let scope = audio.truncated ? " (first two hours)" : ""
            recordEvent(.speakerPass, "Speaker pass found \(count) speaker\(count == 1 ? "" : "s") in \(TranscriptExport.clock(result.durationSeconds)) of audio\(scope), \(String(format: "%.1f", result.processingSeconds)) s of processing.", duration: result.durationSeconds, session: id)
            notice = "Speaker pass finished: \(count) speakers" + (recognized.isEmpty ? "." : ", recognized \(recognized.joined(separator: ", ")).")
        } catch {
            recordEvent(.processingError, "Speaker pass: \(error.localizedDescription)", session: id)
            notice = "Speaker pass failed: \(error.localizedDescription)"
        }
    }

    /// Names each session speaker whose voice matches a remembered person, unless the speaker was named already, and folds the session's embedding into that person so the voice improves over time. Returns the names recognized.
    private func recognizeSpeakers(_ speakers: [String: [Float]], session id: String) throws -> [String] {
        guard let store, let peopleStore else { return [] }
        let people = try peopleStore.list()
        let labels = try store.labels(sessionID: id)
        var recognized: [String] = []
        for match in PeopleMatcher.assignments(speakers: speakers, people: people) {
            guard let person = people.first(where: { $0.id == match.id }), let embedding = speakers[match.speaker] else { continue }
            if labels[match.speaker] == nil { try store.label(sessionID: id, speakerID: match.speaker, name: person.name) }
            try peopleStore.updateEmbedding(id: person.id, with: embedding)
            recognized.append(person.name)
        }
        if !recognized.isEmpty { refreshPeople() }
        return recognized
    }

    private func flushAmbient() {
        guard !ambient.isEmpty else { return }
        let samples = ambient; ambient = []; silentSeconds = 0
        let start = ambientOffset; ambientOffset += AudioClock.seconds(samples: samples.count)
        guard samples.count >= Self.minimumJobSamples else { return }
        if jobs.filter({ $0.mode == .ambient }).count >= 3 {
            droppedSeconds += AudioClock.seconds(samples: samples.count)
            recordEvent(.audioGap, "Inference queue full; segment discarded.", duration: AudioClock.seconds(samples: samples.count))
            notice = "Inference fell behind; bounded audio queue dropped a segment."
            return
        }
        jobs.append(AudioJob(sessionID: sessionID, startedAt: sessionStarted, offset: start, samples: samples, mode: .ambient, ticket: UUID()))
    }

    private func kickWorker() {
        guard lifecycle.phase == .ready, processing == nil, !jobs.isEmpty else { return }
        // Dictation is inserted at the front on release. Never start another ambient job ahead of it.
        if dictationPending && jobs.first?.mode != .dictation { return }
        let job = jobs.removeFirst()
        let generation = lifecycle.generation
        let vocabularySnapshot = dictationVocabulary
        let began = ProcessInfo.processInfo.systemUptime
        let waitSeconds = max(0, began - job.submittedUptime)
        inFlightAudioSeconds = AudioClock.seconds(samples: job.samples.count)
        processing = Task {
            var outcome = PerformanceJob.Outcome.completed
            var inferenceSeconds: Double?
            var cleanupSeconds = 0.0
            var deliverySeconds: Double?
            do {
                let output = try await pipeline.infer(job, tuning: tuning)
                try Task.checkCancellation()
                guard lifecycle.acceptsWork(generation) else { throw CancellationError() }
                inferenceSeconds = output.processingSeconds
                outcome = output.text.isEmpty ? .noSpeech : .completed
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += AudioClock.seconds(samples: job.samples.count)
                lagSeconds = max(0, Date().timeIntervalSince(job.startedAt) - job.offset - AudioClock.seconds(samples: job.samples.count))
                // Persist recognition before awaiting optional cleanup. Capture keeps draining while we await.
                let sources = output.transcripts
                if (job.mode == .ambient || job.submittedUptime > historyClearedAt) && !deletedSessions.contains(job.sessionID) {
                    for transcript in sources { try store?.append(transcript) }
                    // Word evidence is kept in the session's clock so a saved session can be regrouped later. Dictation rows keep none.
                    let words = sources.flatMap { transcript in
                        (output.wordsByTranscript[transcript.id] ?? []).enumerated().map { position, word in
                            StoredWord(transcriptID: transcript.id, position: position, word: word.text, startSeconds: job.offset + word.start, endSeconds: job.offset + word.end, probabilities: word.probabilities)
                        }
                    }
                    try store?.appendWords(words)
                    if !sources.isEmpty {
                        lastTranscriptAt = Date()
                        if job.mode == .ambient, job.sessionID == sessionID { lastAmbientRowAt = Date() }
                        // Live must see recognition before the model's cleanup suspension.
                        refreshRecent(); refreshSessions()
                    }
                }
                let originalTexts = sources.map(\.text)
                var readable = originalTexts
                let wantsCleanup = job.mode == .dictation ? cleanUpDictation : (cleanUpTranscriptions && !dictationActive && !dictationPending)
                if wantsCleanup {
                    let cleanupBegan = ProcessInfo.processInfo.systemUptime
                    readable = await transcriptCleanup.clean(originalTexts)
                    cleanupSeconds = ProcessInfo.processInfo.systemUptime - cleanupBegan
                    try Task.checkCancellation()
                    guard lifecycle.acceptsWork(generation) else { throw CancellationError() }
                    if !(job.mode == .dictation ? cleanUpDictation : cleanUpTranscriptions) { readable = originalTexts }
                }
                if (job.mode == .ambient || job.submittedUptime > historyClearedAt) && !deletedSessions.contains(job.sessionID) {
                    for (source, text) in zip(sources, readable) where source.text != text {
                        try store?.setReadableText(text, for: source)
                    }
                    if readable != originalTexts { refreshRecent(); refreshSessions() }
                }
                if job.mode == .dictation, job.ticket == dictationTicket {
                    let text = DictationCleanup.applying(to: vocabularySnapshot.applyingToDictation(readable.isEmpty ? output.text : readable.joined(separator: " ")))
                    if text.isEmpty { notice = "No text to insert." }
                    else {
                        let deliveryBegan = ProcessInfo.processInfo.systemUptime
                        defer { deliverySeconds = ProcessInfo.processInfo.systemUptime - deliveryBegan }
                        let delivery = try await input.insert(text)
                        if job.ticket == dictationTicket {
                            outcome = delivery.verified ? .completed : .deliveryUnverified
                            notice = delivery.verified ? "" : "Speech transcribed; text delivery could not be verified. Check the target field."
                        }
                    }
                }
            } catch {
                outcome = error is CancellationError ? .cancelled : .failed
                if !(error is CancellationError) { recordEvent(.processingError, error.localizedDescription, session: job.sessionID) }
                if lifecycle.acceptsWork(generation), job.mode != .dictation || job.ticket == dictationTicket {
                    notice = "\(job.mode.rawValue.capitalized): \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            if job.mode == .dictation, job.ticket != dictationTicket { outcome = .cancelled }
            diagnostics.record(.init(elapsedSeconds: ProcessInfo.processInfo.systemUptime - diagnosticsBegan,
                mode: job.mode == .dictation ? .dictation : .ambient, outcome: outcome,
                audioSeconds: AudioClock.seconds(samples: job.samples.count), queueWaitSeconds: waitSeconds,
                inferenceSeconds: inferenceSeconds, completionSeconds: max(0, ProcessInfo.processInfo.systemUptime - job.submittedUptime),
                cleanupSeconds: cleanupSeconds, deliverySeconds: deliverySeconds))
            inFlightAudioSeconds = 0
            if job.mode == .dictation, job.ticket == dictationTicket { input.discardTarget(); dictationPending = false }
            processing = nil
            samplePerformance()
            kickWorker()
        }
    }

    private func recordEvent(_ kind: CaptureEventKind, _ detail: String, duration: Double? = nil, session: String? = nil) {
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
        do { try store?.appendEvent(CaptureEvent(sessionID: session ?? sessionID, kind: kind.rawValue, detail: detail, durationSeconds: duration)); events = try store?.events(limit: 50) ?? [] }
        catch { notice = "Could not save capture event: \(error.localizedDescription)" }
    }

    func refreshRecent() {
        do {
            recent = try store?.recent(limit: 20) ?? []
            events = try store?.events(limit: 50) ?? []
            refreshHistory()
            transcriptRevision += 1
        }
        catch { notice = error.localizedDescription }
    }
    func searchHistory(_ query: String) { historyQuery = query; historyLimit = 50; refreshHistory() }
    func loadMoreHistory() { historyLimit += 50; refreshHistory() }
    private func refreshHistory() {
        do {
            // Store limits each request to 200; page so the UI can browse its whole history.
            var found: [Transcript] = []
            while found.count < historyLimit + 1 {
                let count = min(200, historyLimit + 1 - found.count)
                // History is the dictation list; ambient rows are read from Sessions.
                let page = try historyQuery.isEmpty ? store?.recent(mode: "dictation", limit: count, offset: found.count) : store?.search(historyQuery, mode: "dictation", limit: count, offset: found.count)
                let items = page ?? []; found.append(contentsOf: items)
                if items.count < count { break }
            }
            hasMoreHistory = found.count > historyLimit
            dictationCount = try store?.count(mode: "dictation") ?? 0
            let groups = TranscriptGrouping.historyGroups(Array(found.prefix(historyLimit)), tuning: tuning)
            history = groups.map(\.transcript)
            historySources = Dictionary(uniqueKeysWithValues: groups.map { ($0.transcript.id, $0.sourceIDs) })
        } catch { notice = error.localizedDescription }
    }
    /// Names one speaker in one session. With a voice, the name is also remembered: the embedding joins the person of that name, or starts a new one.
    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]? = nil) {
        do {
            try store?.label(sessionID: session, speakerID: speaker, name: name); refreshRecent()
            if let voice, let peopleStore {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let person = try peopleStore.list().first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { try peopleStore.updateEmbedding(id: person.id, with: voice) }
                else { try peopleStore.add(name: trimmed, embedding: voice) }
                refreshPeople()
            }
        } catch { notice = error.localizedDescription }
    }
    /// The speaker pass's voice embedding for one speaker of one session; nil before the pass or for a speaker it did not find.
    func passEmbedding(session: String, speaker: String) -> [Float]? {
        (try? speakerStore?.speakers(sessionID: session))?.first { $0.speakerID == speaker }?.embedding
    }
    func refreshPeople() {
        do { people = try peopleStore?.list() ?? [] } catch { notice = error.localizedDescription }
    }
    func renamePerson(_ id: String, name: String) {
        do { try peopleStore?.rename(id: id, name: name); refreshPeople() } catch { notice = error.localizedDescription }
    }
    /// Forgets the voice only; names already written into sessions stay.
    func deletePerson(_ id: String) {
        do { try peopleStore?.delete(id: id); refreshPeople(); notice = "Person deleted. Their voice is forgotten." } catch { notice = error.localizedDescription }
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
        if ambientEnabled { recordEvent(.stopped, "Application quit; capture ended.") }
        modelCheck?.cancel(); preparation?.cancel(); processing?.cancel(); diagnostic?.cancel(); pausing?.cancel()
        timer?.invalidate(); cancelDictation(); input.disable(); capture.stop(); updateKeepAwakeAssertion(); server?.stop()
        inputWatcher?.stop(); inputWatcher = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    private func updateKeepAwakeAssertion() {
        keepAwake.setActive(keepMacAwakeWhileListening && ambientEnabled && capture.running)
    }
}
