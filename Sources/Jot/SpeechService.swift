import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import FluidAudio

@MainActor
final class SpeechService: ObservableObject {
    @Published var lifecycle = ServiceLifecycle()
    @Published var fnRequested = UserDefaults.standard.bool(forKey: "fnRequested")
    @Published var ambientRequested = false
    @Published private(set) var ambientEnabled = false
    @Published var mode = "paused"
    @Published var modelState = "not loaded"
    @Published var notice = ""
    @Published var recent: [Transcript] = []
    @Published var history: [Transcript] = []
    @Published var events: [CaptureEvent] = []
    @Published var hasMoreHistory = false
    @Published var modelUpdates = ModelUpdate.defaults
    @Published var checkingModels = false
    @Published var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
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
            if let data = try? JSONEncoder().encode(tuning.bounded) { UserDefaults.standard.set(data, forKey: "transcriptionTuning") }
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

    private var modelCheck: Task<Void, Never>?
    private var historyQuery = ""
    private var historyLimit = 50
    @Published var resources = ResourceSnapshot()
    #if DEBUG
    private var diagnostics = PerformanceDiagnostics(build: .debug)
    #else
    private var diagnostics = PerformanceDiagnostics(build: .release)
    #endif
    private let diagnosticsBegan = ProcessInfo.processInfo.systemUptime
    private var inFlightAudioSeconds = 0.0

    private func samplePerformance() {
        resources = sampler.sample()
        guard resources.valid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - diagnosticsBegan
        diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: resources.physicalFootprintMiB,
            residentMiB: resources.residentMiB, cpuPercent: resources.processCPUPercent,
            droppedAudioSeconds: droppedSeconds, bufferedAudioSeconds: Double(capture.bufferedSampleCount + ambient.count + dictation.count) / 16000 + inFlightAudioSeconds,
            queuedAudioSeconds: jobs.reduce(0) { $0 + Double($1.samples.count) / 16000 }, loadedHistoryRows: history.count,
            modelsReady: modelState == "ready", ambientEnabled: ambientEnabled, dictationActive: dictationActive,
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
    private let capture = MicrophoneCapture()
    private let pipeline = SpeechPipeline()
    private let sampler = ResourceSampler()
    private var store: TranscriptStore?
    private var server: LocalServiceServer?
    private var timer: Timer?
    private var diagnosticActive = false
    private var preparation: Task<Void, Never>?
    private var pausing: Task<Void, Never>?
    private var diagnostic: Task<SpeechOutput, Error>?
    private var tickCount = 0
    private var sessionID = UUID().uuidString
    private var sessionStarted = Date()
    private var ambientOffset = 0.0
    private var ambient: [Float] = []
    private var silentSeconds = 0.0
    private var dictation: [Float] = []
    private var dictationActive = false
    private var dictationPending = false
    private var dictationTicket = UUID()
    private var dictationStarted = Date()
    private var jobs: [AudioJob] = []
    private var processing: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    private lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.beginDictation() }, onStop: { [weak self] in self?.endDictation() })
        result.canStart = { [weak self] in
            guard let self else { return false }
            return self.lifecycle.phase == .ready && self.modelState == "ready" && !self.dictationPending && !self.dictationActive && !self.diagnosticActive
        }
        result.onError = { [weak self] error in
            self?.notice = error.localizedDescription
            self?.cancelDictation()
        }
        return result
    }()

    func launch() {
        markPerformance(.launch)
        do { vocabulary = try vocabularyPreferences.load() }
        catch { vocabularyLoadError = "Could not load vocabulary. Saved entries were preserved. " + error.localizedDescription }
        do {
            store = try TranscriptStore()
            let service = LocalServiceServer { [weak self] data in
                guard let self else { return Data("{\"ok\":false,\"error\":\"Service unavailable\"}".utf8) }
                return await self.handle(data)
            }
            try service.start(); server = service
            if let data = UserDefaults.standard.data(forKey: "transcriptionTuning"),
               let saved = try? JSONDecoder().decode(TranscriptionTuning.self, from: data) { tuning = saved.bounded }
            refreshRecent(); refreshSessions()
            if let data = UserDefaults.standard.data(forKey: "modelUpdateChecks"),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            if UserDefaults.standard.bool(forKey: "modelsPrepared"), !UserDefaults.standard.bool(forKey: "servicePaused") { prepare() }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
        promptForPermissionsAtLaunch()
        scheduleTimer()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.recordEvent("sleep", "Capture paused because the Mac is sleeping."); self?.pause(); self?.notice = "Paused for sleep."
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ambientEnabled || self.dictationActive else { return }
                self.recordEvent("device_change", "Audio input configuration changed."); self.pause(); self.notice = "Audio input changed. Resume when ready."
            }
        })
    }

    var isPaused: Bool { lifecycle.phase == .paused || lifecycle.phase == .pausing || lifecycle.phase == .failed }
    var isTransitioning: Bool { lifecycle.phase == .starting || lifecycle.phase == .pausing }

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
        cachedModelBytes = ModelCache.bytesOnDisk()
        if cachedModelBytes == 0 && !confirmingDownload {
            downloadPrompt = ModelCache.expectedBytes
            return
        }
        downloadPrompt = nil
        guard let token = lifecycle.beginStart() else { return }
        UserDefaults.standard.set(false, forKey: "servicePaused")
        preparing = true; modelState = "preparing"; updateMode()
        markPerformance(.resume); markPerformance(.modelLoadStarted)
        notice = "Loading models…"
        preparation = Task {
            do {
                try await pipeline.prepare()
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                modelState = "ready"
                markPerformance(.modelsReady)
                UserDefaults.standard.set(true, forKey: "modelsPrepared")
                cachedModelBytes = ModelCache.bytesOnDisk()
                if fnRequested { await enableFn() }
                if ambientRequested { try await activateAmbient() }
                if lifecycle.acceptsWork(token) { notice = "" }
            } catch {
                if lifecycle.finishStart(token, succeeded: false) {
                    modelState = "failed"; notice = error.localizedDescription
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
    private func prepareFromCommand() -> Int64 {
        let pending = ModelCache.bytesOnDisk() == 0 ? ModelCache.expectedBytes : 0
        prepare(confirmingDownload: true)
        return pending
    }

    func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
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
        fnRequested = true; UserDefaults.standard.set(true, forKey: "fnRequested")
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token) else { return }
        guard await requestMic(), lifecycle.acceptsWork(token), fnRequested else { return }
        if !DictationInput.accessibilityGranted { input.requestAccessibility() }
        fnEnabled = input.enable()
        if !fnEnabled { notice = "Enable Accessibility access in System Settings, then switch Fn dictation on again." }
    }

    func disableFn() {
        fnRequested = false; UserDefaults.standard.set(false, forKey: "fnRequested")
        cancelDictation(); input.disable(); fnEnabled = false; notice = ""
    }

    func setAmbient(_ enabled: Bool) async {
        ambientRequested = enabled
        guard lifecycle.phase == .ready else { return }
        if enabled {
            do { try await activateAmbient() }
            catch { ambientRequested = false; notice = error.localizedDescription }
        } else {
            if !dictationActive { capture.stop() }
            drainAudio()
            if ambientEnabled { flushAmbient(); recordEvent("ambient_off", "Ambient transcription switched off.") }
            ambientEnabled = false; updateMode(); level = 0; kickWorker()
        }
    }

    // MARK: Sessions and meetings

    func refreshSessions() {
        do { sessions = try store?.sessions(limit: 200) ?? [] } catch { notice = error.localizedDescription }
    }

    /// Folded and merged rows for reading one session. Stored rows are untouched.
    func sessionParagraphs(_ id: String) -> [Transcript] {
        guard let store else { return [] }
        do { return TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(try store.session(id: id))) }
        catch { notice = error.localizedDescription; return [] }
    }

    func renameSession(_ id: String, title: String) {
        do { try store?.setTitle(sessionID: id, title: title); refreshSessions() }
        catch { notice = error.localizedDescription }
    }

    static var exportDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jot Sessions", isDirectory: true)
    }

    /// Writes one session as Markdown into ~/Documents/Jot Sessions and returns the file.
    @discardableResult
    func exportSession(_ id: String) throws -> URL {
        guard let store else { throw JotError.message("Transcript storage is unavailable.") }
        let rows = try store.session(id: id)
        guard !rows.isEmpty, let session = try store.sessions(limit: 200).first(where: { $0.sessionID == id }) else {
            throw JotError.message("Nothing was transcribed in this session, so there is no file to save.")
        }
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

    /// Stops capture, waits for the queued audio to finish, then writes the file and shows it in Finder.
    @discardableResult
    func endMeeting() async -> URL? {
        lastExport = nil
        let id = sessionID
        let generation = lifecycle.generation
        await setAmbient(false)
        do {
            try await MeetingExportWait.wait(
                isValid: { self.lifecycle.acceptsWork(generation) && self.sessionID == id },
                isComplete: {
                    self.kickWorker()
                    return self.jobs.allSatisfy { $0.mode != "ambient" } && self.processing == nil
                })
        } catch {
            notice = "Meeting export interrupted. Saved transcripts remain in Sessions; no file was exported."
            return nil
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
        ambient = []; silentSeconds = 0; ambientEnabled = true; updateMode()
        recordEvent("started", "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        ambientRequested = true
        if lifecycle.phase == .paused || lifecycle.phase == .failed { prepare() }
        if let preparation { await preparation.value }
        guard lifecycle.phase == .ready else { throw JotError.message("The service is not ready. Wait for Pause to finish, then Resume.") }
        try await activateAmbient()
    }

    /// Stop all speech work immediately, then release models when any active prediction returns.
    func pause() {
        guard let token = lifecycle.beginPause() else { return }
        markPerformance(.pause)
        UserDefaults.standard.set(true, forKey: "servicePaused")
        capture.stop()
        let packet = capture.drain()
        let discarded = Double(packet.samples.count + packet.dropped + ambient.count + dictation.count + jobs.reduce(0) { $0 + $1.samples.count }) / 16000
        if discarded > 0 { recordEvent("audio_discarded", "Unfinished audio discarded by Pause.") }
        if ambientEnabled { recordEvent("paused", "Service paused.") }
        ambientEnabled = false
        cancelDictation(); input.disable(); fnEnabled = false
        ambient.removeAll(keepingCapacity: false); jobs.removeAll(keepingCapacity: false)
        capture.discardBufferedAudio(); queuedSeconds = 0; level = 0
        let loadingTask = preparation, worker = processing, fileTask = diagnostic
        loadingTask?.cancel(); worker?.cancel(); fileTask?.cancel()
        modelState = "unloading"; updateMode(); notice = "Releasing models…"
        scheduleTimer()
        pausing = Task {
            await loadingTask?.value
            await worker?.value
            _ = try? await fileTask?.value
            await pipeline.unload()
            if lifecycle.finishPause(token) {
                modelState = "unloaded"; preparing = false; preparation = nil; notice = ""; updateMode()
                markPerformance(.modelsUnloaded); scheduleTimer()
            }
            pausing = nil
        }
    }

    func stop() { ambientRequested = false; pause() }

    func beginDictation() {
        guard lifecycle.phase == .ready, modelState == "ready", !dictationPending else { return }
        drainAudio()
        do {
            if !capture.running { lastAudioAt = Date() }
            try capture.start()
            dictationVocabulary = vocabulary
            dictation = []; dictationStarted = Date(); dictationTicket = UUID(); dictationActive = true
            updateMode()
            markPerformance(.dictationStarted)
            notice = "Listening for dictation… release Fn to insert."
        } catch { cancelDictation(); notice = error.localizedDescription }
    }

    func endDictation() {
        guard dictationActive else { return }
        if !ambientEnabled { capture.stop() }
        drainAudio()
        guard dictationActive else { return }
        dictationActive = false
        markPerformance(.dictationReleased)
        level = 0
        updateMode()
        guard dictation.count >= 3200 else { dictation = []; input.discardTarget(); notice = "Too little audio to transcribe."; return }
        dictationPending = true
        let job = AudioJob(sessionID: UUID().uuidString, startedAt: dictationStarted, offset: 0,
            samples: dictation, mode: "dictation", ticket: dictationTicket)
        dictation = []; jobs.insert(job, at: 0); notice = "Transcribing dictation locally…"; kickWorker()
    }

    private func cancelDictation() {
        if dictationActive || dictationPending { markPerformance(.dictationCancelled) }
        input.discardTarget()
        dictationActive = false; dictationPending = false; dictationTicket = UUID(); dictation = []
        jobs.removeAll { $0.mode == "dictation" }
        if !ambientEnabled { capture.stop() }
        updateMode()
    }

    private func tick() {
        if lifecycle.phase == .ready { drainAudio() }
        tickCount += 1
        if Date().timeIntervalSince(lastStatsTime) >= 1 {
            samplePerformance(); lastStatsTime = Date(); refreshPermissions()
            queuedSeconds = jobs.reduce(0) { $0 + Double($1.samples.count) / 16000 }
            if ambientEnabled || dictationActive, let lastAudioAt, Date().timeIntervalSince(lastAudioAt) > 4 {
                recordEvent("input_stalled", "No microphone samples for more than four seconds."); pause(); notice = "Microphone stopped delivering audio. Resume to reconnect; a capture gap occurred."
            }
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
            let lostSeconds = Double(packet.dropped + ambient.count) / 16000
            droppedSeconds += lostSeconds
            recordEvent("audio_gap", "Capture queue overflow discarded audio.", duration: lostSeconds)
            // End attribution continuity rather than silently stitching across lost audio.
            ambientOffset += Double(ambient.count + packet.dropped) / 16000; ambient = []
            notice = "Audio backlog overflow: a gap was recorded."
        }
        if dictationActive {
            if dictation.count + packet.samples.count <= 960000 { dictation.append(contentsOf: packet.samples) }
            else { cancelDictation(); notice = "Dictation exceeded 60 seconds; cancelled without inserting a partial prompt." }
        }
        if ambientEnabled {
            ambient.append(contentsOf: packet.samples)
            silentSeconds = packet.rms < 0.002 ? silentSeconds + Double(packet.samples.count) / 16000 : 0
            // Blocks run up to 20 s and only break on a 2 s silence, so most sentences reach the recognizer whole.
            if ambient.count >= 320000 || (ambient.count >= 32000 && silentSeconds >= max(2, tuning.bounded.paragraphPause)) { flushAmbient() }
        }
    }

    private func flushAmbient() {
        guard !ambient.isEmpty else { return }
        let samples = ambient; ambient = []; silentSeconds = 0
        let start = ambientOffset; ambientOffset += Double(samples.count) / 16000
        guard samples.count >= 3200 else { return }
        if jobs.filter({ $0.mode == "ambient" }).count >= 3 {
            droppedSeconds += Double(samples.count) / 16000
            recordEvent("audio_gap", "Inference queue full; segment discarded.", duration: Double(samples.count) / 16000)
            notice = "Inference fell behind; bounded audio queue dropped a segment."
            return
        }
        jobs.append(AudioJob(sessionID: sessionID, startedAt: sessionStarted, offset: start, samples: samples, mode: "ambient", ticket: UUID()))
    }

    private func kickWorker() {
        guard lifecycle.phase == .ready, processing == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        let generation = lifecycle.generation
        let vocabularySnapshot = dictationVocabulary
        let began = ProcessInfo.processInfo.systemUptime
        let waitSeconds = max(0, began - job.submittedUptime)
        inFlightAudioSeconds = Double(job.samples.count) / 16000
        processing = Task {
            var outcome = PerformanceJob.Outcome.completed
            var inferenceSeconds: Double?
            do {
                let output = try await pipeline.infer(job, tuning: tuning)
                try Task.checkCancellation()
                guard lifecycle.acceptsWork(generation) else { throw CancellationError() }
                inferenceSeconds = output.processingSeconds
                outcome = output.text.isEmpty ? .noSpeech : .completed
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += Double(job.samples.count) / 16000
                lagSeconds = max(0, Date().timeIntervalSince(job.startedAt) - job.offset - Double(job.samples.count) / 16000)
                for transcript in output.transcripts { try store?.append(transcript) }
                if !output.transcripts.isEmpty { lastTranscriptAt = Date(); refreshRecent(); refreshSessions() }
                if job.mode == "dictation", job.ticket == dictationTicket {
                    let text = DictationCleanup.applying(to: vocabularySnapshot.applying(to: output.text))
                    if text.isEmpty { notice = "No text to insert. Original transcript saved locally." }
                    else {
                        let delivery = try await input.insert(text)
                        if job.ticket == dictationTicket {
                            outcome = delivery.verified ? .completed : .deliveryUnverified
                            notice = delivery.verified ? "Dictation inserted and verified. Original transcript saved locally." : "Speech transcribed; text delivery could not be verified. Check the target field. The transcript is saved below."
                        }
                    }
                }
            } catch {
                outcome = error is CancellationError ? .cancelled : .failed
                if !(error is CancellationError) { recordEvent("processing_error", error.localizedDescription, session: job.sessionID) }
                if lifecycle.acceptsWork(generation), job.mode != "dictation" || job.ticket == dictationTicket {
                    notice = "\(job.mode.capitalized): \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            if job.mode == "dictation", job.ticket != dictationTicket { outcome = .cancelled }
            diagnostics.record(.init(elapsedSeconds: ProcessInfo.processInfo.systemUptime - diagnosticsBegan,
                mode: job.mode == "dictation" ? .dictation : .ambient, outcome: outcome,
                audioSeconds: Double(job.samples.count) / 16000, queueWaitSeconds: waitSeconds,
                inferenceSeconds: inferenceSeconds, completionSeconds: max(0, ProcessInfo.processInfo.systemUptime - job.submittedUptime)))
            inFlightAudioSeconds = 0
            if job.mode == "dictation", job.ticket == dictationTicket { input.discardTarget(); dictationPending = false }
            processing = nil
            samplePerformance()
            kickWorker()
        }
    }

    private func recordEvent(_ kind: String, _ detail: String, duration: Double? = nil, session: String? = nil) {
        let marker: PerformanceEventKind?
        switch kind {
        case "started": marker = .ambientStarted
        case "ambient_off": marker = .ambientStopped
        case "sleep": marker = .sleep
        case "device_change": marker = .deviceChange
        case "audio_gap": marker = .audioGap
        case "processing_error": marker = .processingFailed
        default: marker = nil
        }
        if let marker { markPerformance(marker) }
        do { try store?.appendEvent(CaptureEvent(sessionID: session ?? sessionID, kind: kind, detail: detail, durationSeconds: duration)); events = try store?.events(limit: 50) ?? [] }
        catch { notice = "Could not save capture event: \(error.localizedDescription)" }
    }

    func refreshRecent() {
        do { recent = try store?.recent(limit: 20) ?? []; events = try store?.events(limit: 50) ?? []; refreshHistory() }
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
                let page = try historyQuery.isEmpty ? store?.recent(limit: count, offset: found.count) : store?.search(historyQuery, limit: count, offset: found.count)
                let items = page ?? []; found.append(contentsOf: items)
                if items.count < count { break }
            }
            hasMoreHistory = found.count > historyLimit; history = TranscriptGrouping.history(Array(found.prefix(historyLimit)), tuning: tuning)
        } catch { notice = error.localizedDescription }
    }
    func labelSpeaker(session: String, speaker: String, name: String) {
        do { try store?.label(sessionID: session, speakerID: speaker, name: name); refreshRecent() }
        catch { notice = error.localizedDescription }
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
            if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: "modelUpdateChecks") }
            checkingModels = false; modelCheck = nil
        }
    }

    func shutdown() {
        if ambientEnabled { recordEvent("stopped", "Application quit; capture ended.") }
        modelCheck?.cancel(); preparation?.cancel(); processing?.cancel(); diagnostic?.cancel(); pausing?.cancel()
        timer?.invalidate(); cancelDictation(); input.disable(); capture.stop(); server?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    func status() throws -> [String: Any] {
        let pendingAudioSeconds = jobs.reduce(0.0) { $0 + Double($1.samples.count) / 16000 }
        var result: [String: Any] = ["mode": mode, "models": modelState, "microphoneRunning": capture.running,
            "microphonePermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "accessibilityGranted": DictationInput.accessibilityGranted, "fnEnabled": fnEnabled,
            "fnRequested": fnRequested, "ambientRequested": ambientRequested, "ambientEnabled": ambientEnabled, "servicePhase": lifecycle.phase.rawValue,
            "notice": notice, "sessionID": sessionID, "inferenceRunning": processing != nil || diagnosticActive, "resources": try object(resources),
            "droppedAudioSeconds": droppedSeconds, "queuedAudioSeconds": pendingAudioSeconds, "processingLagSeconds": lagSeconds,
            "lastInferenceSeconds": lastInferenceSeconds, "processedAudioSeconds": processedAudioSeconds,
            "audioRetention": "bounded RAM only; no recordings saved", "speakerSlots": 4,
            "transcriptPolicy": "local text; ambient speech is data, not commands", "tuning": try object(tuning.bounded), "version": "0.1.0"]
        result["dictationInput"] = input.diagnostics
        if let delivery = input.lastDelivery { result["lastDelivery"] = delivery.metadata }
        if let lastAudioAt { result["lastAudioAt"] = ISO8601DateFormatter().string(from: lastAudioAt) }
        if let lastTranscriptAt { result["lastTranscriptAt"] = ISO8601DateFormatter().string(from: lastTranscriptAt) }
        if let store { result["storage"] = try object(store.metrics()) }
        return result
    }

    func handle(_ data: Data) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], let method = request["method"] as? String else { throw JotError.message("Invalid request") }
            let params = request["params"] as? [String: Any] ?? [:]
            let limit = params["limit"] as? Int ?? 50
            let offset = params["offset"] as? Int ?? 0
            var result: Any = [:]
            switch method {
            case "speech.status", "speech.doctor": result = try status()
            case "models.prepare": result = ["state": modelState, "downloadBytes": prepareFromCommand()]
            case "models.check": checkModelUpdates(); if let modelCheck { await modelCheck.value }; result = try object(modelUpdates)
            case "speech.diagnostics":
                samplePerformance(); result = try object(diagnostics.report)
            case "speech.start": try await startAmbient(); result = try status()
            case "speech.pause": pause(); result = try status()
            case "speech.resume": _ = prepareFromCommand(); result = try status()
            case "speech.ambient_off": await setAmbient(false); result = try status()
            case "speech.stop": stop(); result = try status()
            case "speech.meeting_start":
                guard let title = params["title"] as? String else { throw JotError.message("Meeting needs a title") }
                await startMeeting(title)
                guard meetingTitle != nil else { throw JotError.message(notice.isEmpty ? "Meeting did not start" : notice) }
                result = ["sessionID": sessionID, "title": title]
            case "speech.meeting_end":
                let id = sessionID
                guard meetingTitle != nil || ambientEnabled else { throw JotError.message("No meeting or ambient capture is running") }
                let file = await endMeeting()
                result = ["sessionID": id, "file": file?.path ?? ""]
            case "sessions.title":
                guard let id = params["sessionID"] as? String, let title = params["title"] as? String else { throw JotError.message("sessionID and title are required") }
                try store?.setTitle(sessionID: id, title: title); refreshSessions()
                result = ["sessionID": id, "title": title]
            case "transcripts.search": result = try object(store?.search(params["query"] as? String ?? "", limit: limit, offset: offset) ?? [])
            case "transcripts.recent": result = try object(store?.recent(limit: limit, offset: offset) ?? [])
            case "transcripts.events": result = try object(store?.events(sessionID: params["sessionID"] as? String, limit: limit, offset: offset) ?? [])
            case "transcripts.sessions": result = try object(store?.sessions(limit: limit) ?? [])
            case "transcripts.read":
                guard let id = params["id"] as? String, let item = try store?.read(id: id) else { throw JotError.message("Transcript not found") }
                result = try object(item)
            case "transcripts.export":
                guard let id = params["sessionID"] as? String, let store else { throw JotError.message("Session not found") }
                let rows = try store.session(id: id)
                guard let session = try store.sessions(limit: 200).first(where: { $0.sessionID == id }), !rows.isEmpty else { throw JotError.message("Session not found") }
                if params["format"] as? String == "json" { result = try object(TranscriptGrouping.foldContinuations(rows)) }
                else { result = ["sessionID": id, "text": TranscriptExport.markdown(session: session, rows: rows)] }
            case "speech.transcribe_file":
                guard modelState == "ready", !capture.running, processing == nil, jobs.isEmpty, !diagnosticActive else { throw JotError.message("Diagnostic transcription requires ready models and idle capture/inference.") }
                guard let path = params["path"] as? String else { throw JotError.message("path is required") }
                diagnosticActive = true
                defer { diagnosticActive = false }
                let token = lifecycle.generation
                let fileTask = Task { try await pipeline.testFile(URL(fileURLWithPath: path), tuning: tuning) }
                diagnostic = fileTask
                defer { diagnostic = nil }
                let output = try await fileTask.value
                guard lifecycle.acceptsWork(token) else { throw CancellationError() }
                result = ["text": output.text, "transcripts": try object(output.transcripts), "processingSeconds": output.processingSeconds, "persisted": false]
            case "speakers.label":
                guard let session = params["sessionID"] as? String, let speaker = params["speakerID"] as? String, let name = params["name"] as? String else { throw JotError.message("sessionID, speakerID and name are required") }
                try store?.label(sessionID: session, speakerID: speaker, name: name); refreshRecent(); result = ["updated": true]
            default: throw JotError.message("Unknown method: \(method)")
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])) ?? Data()
        }
    }
}
