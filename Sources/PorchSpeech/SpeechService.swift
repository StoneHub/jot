import AppKit
import AVFoundation
import Combine
import Foundation
import PorchCore
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
    @Published var tuning = TranscriptionTuning() {
        didSet {
            if let data = try? JSONEncoder().encode(tuning.bounded) { UserDefaults.standard.set(data, forKey: "transcriptionTuning") }
            refreshHistory()
        }
    }
    private var modelCheck: Task<Void, Never>?
    private var historyQuery = ""
    private var historyLimit = 50
    @Published var resources = ResourceSnapshot()
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
        do {
            store = try TranscriptStore()
            let service = LocalServiceServer { [weak self] data in
                guard let self else { return Data("{\"ok\":false,\"error\":\"Service unavailable\"}".utf8) }
                return await self.handle(data)
            }
            try service.start(); server = service
            if let data = UserDefaults.standard.data(forKey: "transcriptionTuning"),
               let saved = try? JSONDecoder().decode(TranscriptionTuning.self, from: data) { tuning = saved.bounded }
            refreshRecent()
            if let data = UserDefaults.standard.data(forKey: "modelUpdateChecks"),
               let saved = try? JSONDecoder().decode([ModelUpdate].self, from: data) { modelUpdates = saved }
            if UserDefaults.standard.bool(forKey: "modelsPrepared"), !UserDefaults.standard.bool(forKey: "servicePaused") { prepare() }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
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

    func prepare() {
        guard let token = lifecycle.beginStart() else { return }
        UserDefaults.standard.set(false, forKey: "servicePaused")
        preparing = true; modelState = "preparing"; updateMode()
        notice = "Loading models…"
        preparation = Task {
            do {
                try await pipeline.prepare()
                try Task.checkCancellation()
                guard lifecycle.finishStart(token, succeeded: true) else { return }
                modelState = "ready"
                UserDefaults.standard.set(true, forKey: "modelsPrepared")
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
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            notice = "Microphone access is required. Enable Porch Speech in System Settings → Privacy & Security → Microphone."
            return false
        }
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

    private func activateAmbient() async throws {
        let token = lifecycle.generation
        guard lifecycle.acceptsWork(token), !diagnosticActive else { throw PorchError.message("Resume the service before listening.") }
        guard await requestMic() else { throw PorchError.message("Microphone permission is required.") }
        guard lifecycle.acceptsWork(token), ambientRequested else { return }
        guard !ambientEnabled else { return }
        if !capture.running { lastAudioAt = Date() }
        try capture.start()
        sessionID = UUID().uuidString; sessionStarted = Date(); ambientOffset = 0
        ambient = []; silentSeconds = 0; ambientEnabled = true; updateMode()
        recordEvent("started", "Ambient microphone capture started."); notice = ""
    }

    func startAmbient() async throws {
        ambientRequested = true
        if lifecycle.phase == .paused || lifecycle.phase == .failed { prepare() }
        if let preparation { await preparation.value }
        guard lifecycle.phase == .ready else { throw PorchError.message("The service is not ready. Wait for Pause to finish, then Resume.") }
        try await activateAmbient()
    }

    /// Stop all speech work immediately, then release models when any active prediction returns.
    func pause() {
        guard let token = lifecycle.beginPause() else { return }
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
                resources = sampler.sample(); scheduleTimer()
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
            dictation = []; dictationStarted = Date(); dictationTicket = UUID(); dictationActive = true
            updateMode()
            notice = "Listening for dictation… release Fn to insert."
        } catch { cancelDictation(); notice = error.localizedDescription }
    }

    func endDictation() {
        guard dictationActive else { return }
        if !ambientEnabled { capture.stop() }
        drainAudio()
        guard dictationActive else { return }
        dictationActive = false
        level = 0
        updateMode()
        guard dictation.count >= 3200 else { dictation = []; input.discardTarget(); notice = "Too little audio to transcribe."; return }
        dictationPending = true
        let job = AudioJob(sessionID: UUID().uuidString, startedAt: dictationStarted, offset: 0,
            samples: dictation, mode: "dictation", ticket: dictationTicket)
        dictation = []; jobs.insert(job, at: 0); notice = "Transcribing dictation locally…"; kickWorker()
    }

    private func cancelDictation() {
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
            resources = sampler.sample(); lastStatsTime = Date()
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
            if ambient.count >= 160000 || (ambient.count >= 32000 && silentSeconds >= tuning.bounded.paragraphPause) { flushAmbient() }
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
        processing = Task {
            do {
                let output = try await pipeline.infer(job, tuning: tuning)
                try Task.checkCancellation()
                guard lifecycle.acceptsWork(generation) else { throw CancellationError() }
                lastInferenceSeconds = output.processingSeconds
                processedAudioSeconds += Double(job.samples.count) / 16000
                lagSeconds = max(0, Date().timeIntervalSince(job.startedAt) - job.offset - Double(job.samples.count) / 16000)
                for transcript in output.transcripts { try store?.append(transcript) }
                if !output.transcripts.isEmpty { lastTranscriptAt = Date(); refreshRecent() }
                if job.mode == "dictation", job.ticket == dictationTicket {
                    if output.text.isEmpty { notice = "No speech detected; nothing inserted." }
                    else {
                        let delivery = try await input.insert(output.text)
                        if job.ticket == dictationTicket {
                            notice = delivery.verified ? "Dictation inserted and verified. Original transcript saved locally." : "Speech transcribed; text delivery could not be verified. Check the target field. The transcript is saved below."
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) { recordEvent("processing_error", error.localizedDescription, session: job.sessionID) }
                if lifecycle.acceptsWork(generation), job.mode != "dictation" || job.ticket == dictationTicket {
                    notice = "\(job.mode.capitalized): \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            if job.mode == "dictation", job.ticket == dictationTicket { input.discardTarget(); dictationPending = false }
            processing = nil
            kickWorker()
        }
    }

    private func recordEvent(_ kind: String, _ detail: String, duration: Double? = nil, session: String? = nil) {
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
        if let delivery = input.lastDelivery { result["lastDelivery"] = delivery.metadata }
        if let lastAudioAt { result["lastAudioAt"] = ISO8601DateFormatter().string(from: lastAudioAt) }
        if let lastTranscriptAt { result["lastTranscriptAt"] = ISO8601DateFormatter().string(from: lastTranscriptAt) }
        if let store { result["storage"] = try object(store.metrics()) }
        return result
    }

    func handle(_ data: Data) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], let method = request["method"] as? String else { throw PorchError.message("Invalid request") }
            let params = request["params"] as? [String: Any] ?? [:]
            let limit = params["limit"] as? Int ?? 50
            let offset = params["offset"] as? Int ?? 0
            var result: Any = [:]
            switch method {
            case "speech.status", "speech.doctor": result = try status()
            case "models.prepare": prepare(); result = ["state": modelState]
            case "models.check": checkModelUpdates(); if let modelCheck { await modelCheck.value }; result = try object(modelUpdates)
            case "speech.start": try await startAmbient(); result = try status()
            case "speech.pause": pause(); result = try status()
            case "speech.resume": prepare(); result = try status()
            case "speech.ambient_off": await setAmbient(false); result = try status()
            case "speech.stop": stop(); result = try status()
            case "transcripts.search": result = try object(store?.search(params["query"] as? String ?? "", limit: limit, offset: offset) ?? [])
            case "transcripts.recent": result = try object(store?.recent(limit: limit, offset: offset) ?? [])
            case "transcripts.events": result = try object(store?.events(sessionID: params["sessionID"] as? String, limit: limit, offset: offset) ?? [])
            case "transcripts.sessions": result = try object(store?.sessions(limit: limit) ?? [])
            case "transcripts.read":
                guard let id = params["id"] as? String, let item = try store?.read(id: id) else { throw PorchError.message("Transcript not found") }
                result = try object(item)
            case "speech.transcribe_file":
                guard modelState == "ready", !capture.running, processing == nil, jobs.isEmpty, !diagnosticActive else { throw PorchError.message("Diagnostic transcription requires ready models and idle capture/inference.") }
                guard let path = params["path"] as? String else { throw PorchError.message("path is required") }
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
                guard let session = params["sessionID"] as? String, let speaker = params["speakerID"] as? String, let name = params["name"] as? String else { throw PorchError.message("sessionID, speakerID and name are required") }
                try store?.label(sessionID: session, speakerID: speaker, name: name); refreshRecent(); result = ["updated": true]
            default: throw PorchError.message("Unknown method: \(method)")
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])) ?? Data()
        }
    }
}
