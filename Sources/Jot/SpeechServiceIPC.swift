import AVFoundation
import Foundation
import JotCore
import JotEngine

/// The local socket API. Method names and response shapes are the contract the jot CLI and its MCP server depend on.
extension SpeechService {
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    /// A JSON object crossing back from a detached task. `@unchecked` because `JSONSerialization` hands back `Any`.
    private struct JSONValue: @unchecked Sendable { let value: Any }

    /// A store read and its JSON encoding, off the main actor: a follower paging through history must not stall the screens
    /// or the recognition that shares the store lock with it. The store serializes its own SQLite access.
    private func readOffMain<T: Encodable & Sendable>(_ read: @escaping @Sendable () throws -> T) async throws -> Any {
        try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return JSONValue(value: try JSONSerialization.jsonObject(with: encoder.encode(try read())))
        }.value.value
    }

    /// Paused means no intake from any input: the hooks are refused like the microphone is off. The hook CLI stays silent.
    static let pausedIntake = "Jot is paused, so agent context is not taken. Resume listening to give agents context."

    /// One setting as `jot settings` lists it, after a change.
    private func settingRow(_ key: String) -> [String: Any] { settings.report().first { $0["key"] as? String == key } ?? [:] }

    func status() async throws -> [String: Any] {
        let pendingAudioSeconds = transcriber.queuedAudioSeconds
        let audioRetention = StatusReport.audioRetention(keepForSpeakerPass: keepAudioForSpeakerPass,
                                                         keepTuningCopy: settings.bool(JotSettings.keepTuningAudio))
        var result: [String: Any] = ["mode": mode, "models": modelState.rawValue, "microphoneRunning": capture.running,
            "microphonePermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "suggestions": suggestions.diagnostics,
            "accessibilityGranted": DictationInput.accessibilityGranted, "dictationEnabled": dictationEnabled, "fnEnabled": dictationEnabled,
            "dictationShortcut": shortcut.displayName, "dictationRequested": dictationRequested, "fnRequested": dictationRequested, "ambientRequested": ambientRequested, "ambientEnabled": ambientEnabled, "keepMacAwakeWhileListening": keepMacAwakeWhileListening, "keepAwakeActive": keepAwakeActive, "servicePhase": lifecycle.phase.rawValue,
            "notice": notice, "sessionID": timeline.sessionID, "inferenceRunning": transcriber.processing != nil || diagnosticActive, "speakerPassRunning": speakers.passRunning, "resources": try object(resources),
            "droppedAudioSeconds": droppedSeconds, "queuedAudioSeconds": pendingAudioSeconds, "processingLagSeconds": transcriber.lagSeconds,
            "lastInferenceSeconds": transcriber.lastInferenceSeconds, "processedAudioSeconds": transcriber.processedAudioSeconds,
            "audioRetention": audioRetention, "speakerSlots": 4,
            "transcriptPolicy": StatusReport.transcriptPolicy, "tuning": try object(tuning.bounded), "version": JotVersion.current]
        result["transcriptionCleanup"] = ["enabled": cleanUpTranscriptions,
            "dictationEnabled": cleanUpDictation,
            "availability": TranscriptCleanup.availability.rawValue, "model": "Apple on-device"]
        result["microphone"] = ["selected": capture.inputName, "signalLevel": capture.inputLevel,
            "noSignal": capture.inputIsSilent, "findingInput": capture.findingInput, "switching": switchingInput,
            "automatic": automaticMicrophone]
        result["dictationInput"] = input.diagnostics
        result["dictationRecovery"] = recoveryDiagnostics
        if let delivery = input.lastDelivery { result["lastDelivery"] = delivery.metadata }
        if let lastAudioAt { result["lastAudioAt"] = ISO8601DateFormatter().string(from: lastAudioAt) }
        if let lastTranscriptAt = transcriber.lastTranscriptAt { result["lastTranscriptAt"] = ISO8601DateFormatter().string(from: lastTranscriptAt) }
        if let store = library.store { result["storage"] = try await readOffMain { try store.metrics() } }
        let tuningAudio = speakers.tuningAudioDirectory
        result["tuningAudio"] = try await readOffMain { TuningAudio.summary(in: tuningAudio) }
        result["storageWorkPending"] = storeExecutor.pendingCount
        result["speakerPassPending"] = speakers.hasPendingPasses
        assert(StatusReport.conforms(result), "speech.status keys drifted from StatusReport")
        return result
    }

    /// `transcripts.wait` requests in progress, held to `TranscriptWait.maximumWaiters`.
    private static var transcriptWaiters = 0

    /// True while `sessions.notes` runs: one session's notes at a time.
    private static var writingNotes = false

    /// The cursor, generation and session filter `transcripts.since` and `transcripts.wait` share.
    private func feedPosition(_ params: [String: Any]) throws -> (cursor: Int?, generation: String?, sessionID: String?) {
        let cursor = params["cursor"] as? Int
        guard params["cursor"] == nil || (cursor != nil && cursor! >= 0) else { throw JotError.message("cursor must be a nonnegative integer") }
        let generation = params["generation"] as? String
        guard params["generation"] == nil || generation?.isEmpty == false else { throw JotError.message("generation must be a nonempty string") }
        let sessionID = params["sessionID"] as? String
        guard params["sessionID"] == nil || sessionID?.isEmpty == false else { throw JotError.message("sessionID must be a nonempty string") }
        return (cursor, generation, sessionID)
    }

    func handle(_ data: Data) async -> Data {
        await LocalDispatch.handle(data) { try await respond(to: $0) }
    }

    private func respond(to request: LocalRequest) async throws -> Any {
        let params = request.params, limit = request.limit, offset = request.offset
        var result: Any = [:]
        switch request.method {
        case .speechControls:
            result = try object(ControlProjection.controls(mode: mode, meetingActive: meetingTitle != nil,
                dictationActive: dictation.isActive, dictationPending: dictation.isPending,
                lastAttempt: dictation.currentAttempt?.state, dictationSequence: controlSequence,
                suggestion: suggestions.diagnostics, inputLevel: ControlSnapshot.inputLevel(meter: capture.inputLevel)))
        case .speechStatus: result = try await status()
        case .activityReport:
            let days = try ActivityRequest.days(arguments: params)
            guard let store = library.store else { throw JotError.message("Saved history is unavailable") }
            let now = Date(), calendar = Calendar.current
            let report = try await storeExecutor.perform { try store.activity(days: days, now: now, calendar: calendar) }
            result = try object(report)
        case .usageReset:
            guard let store = library.store else { throw JotError.message("Saved history is unavailable") }
            try await storeExecutor.perform { try store.resetUsage() }
            result = ["reset": true]
        case .modelsPrepare: result = ["state": modelState.rawValue, "downloadBytes": prepareFromCommand()]
        case .modelsUnload: unloadModels(); result = try await status()
        case .modelsCheck: checkModelUpdates(); if let modelCheck { await modelCheck.value }; result = try object(modelUpdates)
        case .speechDiagnostics:
            samplePerformance(); result = try object(diagnostics.report)
        case .speechStart: try await startAmbient(); result = try await status()
        case .speechPause: pause(); result = try await status()
        case .speechResume:
            // A click in another app's UI is not consent to a download: it gets the same prompt as Resume in Jot.
            if params["askBeforeDownload"] as? Bool == true { prepare() } else { _ = prepareFromCommand() }
            var resumed = try await status(); resumed["downloadPrompt"] = downloadPrompt != nil; result = resumed
        case .speechMeetingStart:
            guard let title = params["title"] as? String else { throw JotError.message("Meeting needs a title") }
            await startMeeting(title)
            guard meetingTitle != nil else { throw JotError.message(notice.isEmpty ? "Meeting did not start" : notice) }
            result = ["sessionID": timeline.sessionID, "title": title]
        case .speechMeetingEnd:
            let id = timeline.sessionID
            guard meetingTitle != nil || ambientEnabled else { throw JotError.message("No meeting or ambient capture is running") }
            let files = try await endMeeting()
            // "file" is the last part; "files" lists every part when an automatic pause split the meeting.
            result = ["sessionID": id, "file": files.last?.path ?? "", "files": files.map(\.path)]
        case .sessionsTitle:
            guard let id = params["sessionID"] as? String, let title = params["title"] as? String else { throw JotError.message("sessionID and title are required") }
            try await setSessionTitle(id, title: title)
            result = ["sessionID": id, "title": title]
        case .sessionsNotes:
            guard let id = params["sessionID"] as? String, !id.isEmpty else { throw JotError.message("sessionID is required") }
            if let blocker = modelAvailability(.notes).notesBlocker { throw JotError.message(blocker) }
            guard !Self.writingNotes else { throw JotError.message("Jot is already writing notes; try again when they finish.") }
            Self.writingNotes = true
            defer { Self.writingNotes = false }
            let (session, rows) = try await library.exportable(id)
            let model = ChosenModel(.notes, settings: settings)
            let gate = ModelCallGate(deadline: SessionNotes.deadline)
            let notes = try await SessionNotes.write(rows, tuning: tuning) { request in
                await gate.call(request) { try await model.generate($0) }
            }
            result = ["sessionID": id, "title": session.title ?? "", "notes": notes.text, "parts": notes.parts,
                      "onDevice": model.isOnDevice, "model": model.usesCustomModel ? settings.text(JotSettings.customModelName) : "Apple on-device"]
        case .settingsGet: result = ["settings": settings.report(), "revision": JotSettings.revision]
        case .settingsSet:
            guard let key = params["key"] as? String, let value = params["value"] else { throw JotError.message("key and value are required") }
            try settings.set(key, raw: value); settingChanged(key)
            result = settingRow(key)
        case .settingsReset:
            guard let key = params["key"] as? String else { throw JotError.message("key is required") }
            try settings.reset(key); settingChanged(key)
            result = settingRow(key)
        case .transcriptsClear: try await clearHistory(); result = ["cleared": true]
        case .transcriptsDeleteSession:
            guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
            try await deleteSession(id); result = ["deleted": true]
        case .transcriptsSearch:
            let store = library.store, query = params["query"] as? String ?? ""
            result = try await readOffMain { try store?.search(query, limit: limit, offset: offset) ?? [] }
        case .transcriptsRecent:
            let store = library.store
            result = try await readOffMain { try store?.recent(limit: limit, offset: offset) ?? [] }
        case .transcriptsEvents:
            let store = library.store, sessionID = params["sessionID"] as? String
            result = try await readOffMain { try store?.events(sessionID: sessionID, limit: limit, offset: offset) ?? [] }
        case .suggestionsRecent:
            guard let suggestionHistory else { throw JotError.message("Suggestion history is unavailable") }
            result = try object(await suggestionHistory.recent(limit: limit))
        case .transcriptsSessions:
            let store = library.store
            result = try await readOffMain { try store?.sessions(limit: limit) ?? [] }
        case .transcriptsSince:
            let (cursor, generation, sessionID) = try feedPosition(params)
            let store = library.store
            result = try await readOffMain {
                try store?.changes(since: cursor.map(Int64.init), generation: generation, sessionID: sessionID, limit: limit) ?? TranscriptChanges(rows: [], cursor: Int64(cursor ?? 0), hasMore: false)
            }
        case .transcriptsWait:
            let (cursor, generation, sessionID) = try feedPosition(params)
            let timeout = try TranscriptWait.timeout(params)
            guard Self.transcriptWaiters < TranscriptWait.maximumWaiters else { throw JotError.message("\(TranscriptWait.maximumWaiters) clients are already waiting; retry later or poll transcripts.since") }
            Self.transcriptWaiters += 1
            defer { Self.transcriptWaiters -= 1 }
            let store = library.store
            let outcome = try await TranscriptWait.run(cursor: cursor.map(Int64.init), generation: generation, timeout: timeout,
                now: { ProcessInfo.processInfo.systemUptime },
                read: { cursor, generation in
                    try await Task.detached(priority: .userInitiated) {
                        try store?.changes(since: cursor, generation: generation, sessionID: sessionID, limit: limit) ?? TranscriptChanges(rows: [], cursor: cursor ?? 0, hasMore: false)
                    }.value
                },
                sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
            var page = try object(outcome.page) as? [String: Any] ?? [:]
            page["timedOut"] = outcome.timedOut
            result = page
        case .transcriptsRead:
            guard let id = params["id"] as? String else { throw JotError.message("id is required") }
            let store = library.store
            guard let item = try await Task.detached(priority: .userInitiated, operation: { try store?.read(id: id) }).value else { throw JotError.message("Transcript not found") }
            result = try object(item)
        case .transcriptsExport:
            guard let id = params["sessionID"] as? String else { throw JotError.message("sessionID is required") }
            let (session, rows) = try await library.exportable(id)
            if params["format"] as? String == "json" { result = try object(TranscriptGrouping.foldContinuations(rows)) }
            else { result = ["sessionID": id, "text": TranscriptExport.markdown(session: session, rows: rows, tuning: tuning)] }
        case .speechTranscribeFile:
            guard !preparingUpdate, !switchingInput, lifecycle.phase == .paused, !capture.running, transcriber.isIdle, !diagnosticActive else { throw JotError.message("Pause Jot before diagnostic file transcription.") }
            guard ModelCache.bytesOnDisk() > 0 else { throw JotError.message("Prepare speech models before diagnostic file transcription.") }
            guard let path = params["path"] as? String else { throw JotError.message("path is required") }
            diagnosticActive = true
            defer { diagnosticActive = false }
            let token = lifecycle.generation
            // File diagnostics use an isolated pipeline while paused, so they never reset the live speaker timeline.
            let filePipeline = SpeechPipeline(settings: settings)
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
        case .contextAdd:
            guard ambientEnabled else { throw JotError.message(Self.pausedIntake) }
            guard let role = params["role"] as? String, let source = params["source"] as? String, let text = params["text"] as? String else {
                throw JotError.message("context.add needs role, source and text")
            }
            let message = try agentContext.add(role: role, source: source, conversation: params["conversation"] as? String, text: text)
            result = ["id": message.id, "held": agentContext.count, "windowMinutes": suggestionWindowMinutes]
        case .contextHook:
            guard ambientEnabled else { throw JotError.message(Self.pausedIntake) }
            guard let role = params["role"] as? String, let source = params["source"] as? String,
                  ["claude-code", "codex"].contains(source),
                  let conversation = params["conversation"] as? String, !conversation.isEmpty,
                  conversation.utf8.count <= 200,
                  let text = params["text"] as? String,
                  params["eventID"] == nil || ((params["eventID"] as? String).map { !$0.isEmpty && $0.utf8.count <= 512 } == true)
            else { throw JotError.message("Invalid agent hook context") }
            let message = try agentContext.add(role: role, source: source, conversation: conversation,
                                               text: text, turn: params["turn"] as? String,
                                               cwd: params["cwd"] as? String, eventID: params["eventID"] as? String)
            result = ["id": message.id, "held": agentContext.count]
        case .contextClear: agentContext.clear(); result = ["held": 0]
        case .peopleList:
            let iso = ISO8601DateFormatter()
            var rows: [[String: Any]] = []
            if let you = speakers.userVoice {
                // The user's own voice, learned from dictation holds; "you" is its id for people.forget.
                rows.append(["id": "you", "name": UserVoice.label, "sampleCount": you.sampleCount, "heldSeconds": you.heldSeconds,
                             "trusted": you.trusted, "updatedAt": iso.string(from: you.updatedAt)])
            }
            let peopleStore = speakers.peopleStore
            let people = try await storeExecutor.perform { try peopleStore?.list() ?? [] }
            rows += people.map { ["id": $0.id, "name": $0.name, "sampleCount": $0.sampleCount, "createdAt": iso.string(from: $0.createdAt), "updatedAt": iso.string(from: $0.updatedAt)] }
            result = rows
        case .peopleForget, .peopleDelete:
            guard let id = params["id"] as? String else { throw JotError.message("id is required") }
            if id == "you" { speakers.forgetUserVoice() } else { let store = speakers.peopleStore; try await storeExecutor.submit { try store?.delete(id: id) }.value; speakers.refreshPeople() }
            result = ["deleted": true]
        case .speakersLabel:
            guard let session = params["sessionID"] as? String, let speaker = params["speakerID"] as? String, let name = params["name"] as? String else { throw JotError.message("sessionID, speakerID and name are required") }
            // The name is saved before the voice is remembered, so Live shows it even when remembering the voice fails.
            defer { library.reloadLive() }
            try await speakers.labelSpeaker(session: session, speaker: speaker, name: name, voice: await speakers.passEmbedding(session: session, speaker: speaker))
            result = ["updated": true]
        }
        return result
    }
}
