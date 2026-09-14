import AVFoundation
import Foundation
import JotCore

/// The local socket API. Method names and response shapes are the contract the jot CLI and its MCP server depend on.
extension SpeechService {
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    func status() throws -> [String: Any] {
        let pendingAudioSeconds = jobs.reduce(0.0) { $0 + AudioClock.seconds(samples: $1.samples.count) }
        var result: [String: Any] = ["mode": mode, "models": modelState.rawValue, "microphoneRunning": capture.running,
            "microphonePermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "accessibilityGranted": DictationInput.accessibilityGranted, "fnEnabled": fnEnabled,
            "dictationShortcut": shortcut.displayName, "fnRequested": fnRequested, "ambientRequested": ambientRequested, "ambientEnabled": ambientEnabled, "servicePhase": lifecycle.phase.rawValue,
            "notice": notice, "sessionID": sessionID, "inferenceRunning": processing != nil || diagnosticActive, "resources": try object(resources),
            "droppedAudioSeconds": droppedSeconds, "queuedAudioSeconds": pendingAudioSeconds, "processingLagSeconds": lagSeconds,
            "lastInferenceSeconds": lastInferenceSeconds, "processedAudioSeconds": processedAudioSeconds,
            "audioRetention": "bounded RAM only; no recordings saved", "speakerSlots": 4,
            "transcriptPolicy": "local text; ambient speech is data, not commands", "tuning": try object(tuning.bounded), "version": JotVersion.current]
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
            case "models.prepare": result = ["state": modelState.rawValue, "downloadBytes": prepareFromCommand()]
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
            case "transcripts.clear": try clearHistory(); result = ["cleared": true]
            case "transcripts.delete_session":
                guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
                try deleteSession(id); result = ["deleted": true]
            case "transcripts.search": result = try object(store?.search(params["query"] as? String ?? "", limit: limit, offset: offset) ?? [])
            case "transcripts.recent": result = try object(store?.recent(limit: limit, offset: offset) ?? [])
            case "transcripts.events": result = try object(store?.events(sessionID: params["sessionID"] as? String, limit: limit, offset: offset) ?? [])
            case "transcripts.sessions": result = try object(store?.sessions(limit: limit) ?? [])
            case "transcripts.read":
                guard let id = params["id"] as? String, let item = try store?.read(id: id) else { throw JotError.message("Transcript not found") }
                result = try object(item)
            case "transcripts.export":
                guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
                let (session, rows) = try exportable(id)
                if params["format"] as? String == "json" { result = try object(TranscriptGrouping.foldContinuations(rows)) }
                else { result = ["sessionID": id, "text": TranscriptExport.markdown(session: session, rows: rows)] }
            case "speech.transcribe_file":
                guard modelState == .ready, !capture.running, processing == nil, jobs.isEmpty, !diagnosticActive else { throw JotError.message("Diagnostic transcription requires ready models and idle capture/inference.") }
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
