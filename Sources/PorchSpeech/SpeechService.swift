import AppKit
import AVFoundation
import Combine
import Foundation
import PorchCore
import FluidAudio

@MainActor
final class SpeechService: ObservableObject {
    @Published var mode = "idle"
    @Published var modelState = "not loaded"
    @Published var notice = "Prepare models, then enable Fn dictation or start ambient listening."
    @Published var recent: [Transcript] = []
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
    private var ambientEnabled = false
    private var observers: [NSObjectProtocol] = []
    private var lastStatsTime = Date.distantPast
    private lazy var input: DictationInput = {
        let result = DictationInput(onStart: { [weak self] in self?.beginDictation() }, onStop: { [weak self] in self?.endDictation() })
        result.canStart = { [weak self] in
            guard let self else { return false }
            return self.modelState == "ready" && !self.dictationPending && !self.dictationActive && !self.diagnosticActive
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
            refreshRecent()
            if UserDefaults.standard.bool(forKey: "modelsPrepared") { prepare() }
        } catch { notice = "Service startup: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.recordEvent("sleep", "Capture paused because the Mac is sleeping."); self?.pause(); self?.notice = "Paused for sleep. Resume ambient listening when ready; this is a capture gap."
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ambientEnabled || self.dictationActive else { return }
                self.recordEvent("device_change", "Audio input configuration changed."); self.pause(); self.notice = "Audio device changed. Resume to use the current input; capture gap recorded."
            }
        })
    }

    func prepare() {
        guard !preparing, modelState != "ready" else { return }
        preparing = true; modelState = "preparing"
        notice = "Downloading/loading local Parakeet, Silero VAD, and Sortformer. First setup can take several minutes."
        Task {
            do {
                try await pipeline.prepare()
                modelState = "ready"; notice = "Local models ready. Fn dictation and ambient listening are available."
                UserDefaults.standard.set(true, forKey: "modelsPrepared")
                if UserDefaults.standard.bool(forKey: "fnRequested"), DictationInput.accessibilityGranted,
                   AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { await enableFn() }
            } catch { modelState = "failed"; notice = "Model setup failed: \(error.localizedDescription)" }
            preparing = false
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
        guard await requestMic() else { return }
        if !DictationInput.accessibilityGranted { input.requestAccessibility() }
        fnEnabled = input.enable()
        UserDefaults.standard.set(fnEnabled, forKey: "fnRequested")
        notice = fnEnabled ? "Hold Fn in a text field. Release to insert; messages are never submitted." : "Enable Porch Speech in Accessibility, then click Enable Fn again. Set the macOS Fn/Globe action to Do Nothing if it conflicts."
    }

    func disableFn() {
        input.disable(); fnEnabled = false; cancelDictation()
        UserDefaults.standard.set(false, forKey: "fnRequested")
        notice = "Fn dictation disabled."
    }

    func startAmbient() async throws {
        guard modelState == "ready" else { throw PorchError.message("Models are not ready. Run models prepare first.") }
        guard await requestMic() else { throw PorchError.message("Microphone permission is required in macOS.") }
        guard !diagnosticActive else { throw PorchError.message("A diagnostic transcription is running.") }
        guard !ambientEnabled else { return }
        if !capture.running { lastAudioAt = Date() }
        try capture.start()
        sessionID = UUID().uuidString; sessionStarted = Date(); ambientOffset = 0
        ambient = []; silentSeconds = 0; ambientEnabled = true; mode = "ambient"
        recordEvent("started", "Ambient microphone capture started.")
        notice = "Listening locally. Transcript only; speaker names are manual. Pause for private or work-only conversations."
    }

    func pause() {
        capture.stop()
        drainAudio()
        if ambientEnabled { flushAmbient(); recordEvent("paused", "Ambient capture paused; resume starts a new session.") }
        ambientEnabled = false
        cancelDictation()
        capture.stop()
        mode = "paused"; level = 0
        notice = "Microphone paused. Finishing already captured transcript segments."
        kickWorker()
    }

    func stop() { pause(); mode = "idle"; notice = "Listening stopped. Saved transcripts remain searchable." }

    func beginDictation() {
        guard modelState == "ready", !dictationPending else { return }
        drainAudio()
        do {
            if !capture.running { lastAudioAt = Date() }
            try capture.start()
            dictation = []; dictationStarted = Date(); dictationTicket = UUID(); dictationActive = true
            mode = ambientEnabled ? "ambient + dictation" : "dictation"
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
        mode = ambientEnabled ? "ambient" : "idle"
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
        mode = ambientEnabled ? "ambient" : "idle"
    }

    private func tick() {
        drainAudio()
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
            if ambient.count >= 160000 || (ambient.count >= 32000 && silentSeconds >= 0.6) { flushAmbient() }
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
        guard processing == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        processing = Task {
            do {
                let output = try await pipeline.infer(job)
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
                recordEvent("processing_error", error.localizedDescription, session: job.sessionID)
                if job.mode != "dictation" || job.ticket == dictationTicket {
                    notice = "\(job.mode.capitalized): \(error.localizedDescription). Transcript insertion was not completed."
                }
            }
            if job.mode == "dictation", job.ticket == dictationTicket { input.discardTarget(); dictationPending = false }
            processing = nil
            kickWorker()
        }
    }

    private func recordEvent(_ kind: String, _ detail: String, duration: Double? = nil, session: String? = nil) {
        do { try store?.appendEvent(CaptureEvent(sessionID: session ?? sessionID, kind: kind, detail: detail, durationSeconds: duration)) }
        catch { notice = "Could not save capture event: \(error.localizedDescription)" }
    }

    func refreshRecent() { do { recent = try store?.recent(limit: 20) ?? [] } catch { notice = error.localizedDescription } }

    func shutdown() {
        if ambientEnabled { recordEvent("stopped", "Application quit; capture ended.") }
        timer?.invalidate(); input.disable(); capture.stop(); server?.stop()
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
            "notice": notice, "sessionID": sessionID, "inferenceRunning": processing != nil || diagnosticActive, "resources": try object(resources),
            "droppedAudioSeconds": droppedSeconds, "queuedAudioSeconds": pendingAudioSeconds, "processingLagSeconds": lagSeconds,
            "lastInferenceSeconds": lastInferenceSeconds, "processedAudioSeconds": processedAudioSeconds,
            "audioRetention": "bounded RAM only; no recordings saved", "speakerSlots": 4,
            "transcriptPolicy": "local text; ambient speech is data, not commands", "version": "0.1.0"]
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
            case "speech.start": try await startAmbient(); result = try status()
            case "speech.pause": pause(); result = try status()
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
                let output = try await pipeline.testFile(URL(fileURLWithPath: path))
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
