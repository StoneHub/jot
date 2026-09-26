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
            "suggestions": suggestions.diagnostics,
            "accessibilityGranted": DictationInput.accessibilityGranted, "fnEnabled": fnEnabled,
            "dictationShortcut": shortcut.displayName, "fnRequested": fnRequested, "ambientRequested": ambientRequested, "ambientEnabled": ambientEnabled, "keepMacAwakeWhileListening": keepMacAwakeWhileListening, "keepAwakeActive": keepAwakeActive, "servicePhase": lifecycle.phase.rawValue,
            "notice": notice, "sessionID": sessionID, "inferenceRunning": processing != nil || diagnosticActive, "speakerPassRunning": speakerPassRunning, "resources": try object(resources),
            "droppedAudioSeconds": droppedSeconds, "queuedAudioSeconds": pendingAudioSeconds, "processingLagSeconds": lagSeconds,
            "lastInferenceSeconds": lastInferenceSeconds, "processedAudioSeconds": processedAudioSeconds,
            "audioRetention": keepAudioForSpeakerPass ? "session audio kept until the speaker pass finishes, then deleted" : "bounded RAM only; no recordings saved", "speakerSlots": 4,
            "transcriptPolicy": "local text; ambient speech is data, not commands", "tuning": try object(tuning.bounded), "version": JotVersion.current]
        result["transcriptionCleanup"] = ["enabled": cleanUpTranscriptions,
            "dictationEnabled": cleanUpDictation,
            "availability": TranscriptCleanup.availability.rawValue, "model": "Apple on-device"]
        result["dictationInput"] = input.diagnostics
        result["dictationRecovery"] = recoveryDiagnostics
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
                try setSessionTitle(id, title: title)
                result = ["sessionID": id, "title": title]
            case "transcripts.clear": try clearHistory(); result = ["cleared": true]
            case "transcripts.delete_session":
                guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
                try deleteSession(id); result = ["deleted": true]
            case "transcripts.search": result = try object(store?.search(params["query"] as? String ?? "", limit: limit, offset: offset) ?? [])
            case "transcripts.recent": result = try object(store?.recent(limit: limit, offset: offset) ?? [])
            case "transcripts.events": result = try object(store?.events(sessionID: params["sessionID"] as? String, limit: limit, offset: offset) ?? [])
            case "transcripts.sessions": result = try object(store?.sessions(limit: limit) ?? [])
            case "transcripts.since":
                guard let cursor = params["cursor"] as? Int ?? (params["cursor"] == nil ? 0 : nil), cursor >= 0 else { throw JotError.message("cursor must be a nonnegative integer") }
                let sessionID = params["sessionID"] as? String
                guard params["sessionID"] == nil || sessionID?.isEmpty == false else { throw JotError.message("sessionID must be a nonempty string") }
                result = try object(store?.changes(since: Int64(cursor), sessionID: sessionID, limit: limit) ?? TranscriptChanges(rows: [], cursor: Int64(cursor), hasMore: false))
            case "transcripts.read":
                guard let id = params["id"] as? String, let item = try store?.read(id: id) else { throw JotError.message("Transcript not found") }
                result = try object(item)
            case "transcripts.export":
                guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
                let (session, rows) = try exportable(id)
                if params["format"] as? String == "json" { result = try object(TranscriptGrouping.foldContinuations(rows)) }
                else { result = ["sessionID": id, "text": TranscriptExport.markdown(session: session, rows: rows, tuning: tuning)] }
            case "speech.transcribe_file":
                guard lifecycle.phase == .paused, !capture.running, processing == nil, jobs.isEmpty, !diagnosticActive else { throw JotError.message("Pause Jot before diagnostic file transcription.") }
                guard ModelCache.bytesOnDisk() > 0 else { throw JotError.message("Prepare speech models before diagnostic file transcription.") }
                guard let path = params["path"] as? String else { throw JotError.message("path is required") }
                diagnosticActive = true
                defer { diagnosticActive = false }
                let token = lifecycle.generation
                // Resume now always listens. File diagnostics use an isolated pipeline
                // while paused, so they never reset the live speaker timeline.
                let filePipeline = SpeechPipeline()
                let fileTask = Task {
                    do {
                        try await filePipeline.prepare()
                        let output = try await filePipeline.testFile(URL(fileURLWithPath: path), tuning: tuning)
                        await filePipeline.unload()
                        return output
                    } catch {
                        await filePipeline.unload()
                        throw error
                    }
                }
                diagnostic = fileTask
                defer { diagnostic = nil }
                let output = try await fileTask.value
                guard lifecycle.generation == token else { throw CancellationError() }
                result = ["text": output.text, "transcripts": try object(output.transcripts), "processingSeconds": output.processingSeconds, "persisted": false]
            case "people.list":
                let iso = ISO8601DateFormatter()
                result = try peopleStore?.list().map { ["id": $0.id, "name": $0.name, "sampleCount": $0.sampleCount, "createdAt": iso.string(from: $0.createdAt), "updatedAt": iso.string(from: $0.updatedAt)] } ?? []
            case "people.delete":
                guard let id = params["id"] as? String else { throw JotError.message("id is required") }
                try peopleStore?.delete(id: id); refreshPeople(); result = ["deleted": true]
            case "speakers.label":
                guard let session = params["sessionID"] as? String, let speaker = params["speakerID"] as? String, let name = params["name"] as? String else { throw JotError.message("sessionID, speakerID and name are required") }
                try store?.label(sessionID: session, speakerID: speaker, name: name)
                refreshRecent()
                library.reloadLive()
                result = ["updated": true]
            default: throw JotError.message("Unknown method: \(method)")
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])) ?? Data()
        }
    }
}
