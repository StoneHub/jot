import Foundation
import JotCore
import JotEngine
import SQLite3

extension RecoveryFlowChecks {
    /// Live reads its session once and then only adds rows and cleaned text, so every other edit must make it read the session again: a speaker name from the sheet or the socket, a new paragraph pause, and a delete.
    @MainActor static func checkLiveFollowsEdits(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let folder = directory.appendingPathComponent("live-edits")
        let store = try TranscriptStore(directory: folder)
        // Rows 1 and 2 are one speaker's, rows 3 to 5 another's. Each row ends two seconds before the next starts, so the paragraph pause decides whether a speaker's rows join.
        // Block 4 also hands back a row the store refuses, after its first row is saved.
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in
                guard let first = job.samples.first, first > 0 else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
                let index = Int(first)
                let text = "segment\(index)"
                let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset, endSeconds: job.offset + 1,
                    text: text, speakerID: index <= 2 ? "speaker-1" : "speaker-2", mode: "ambient")
                let refused = Transcript(sessionID: job.sessionID, startedAt: job.startedAt, startSeconds: job.offset + 2, endSeconds: job.offset + 1,
                    text: "refused", mode: "ambient")
                return SpeechOutput(transcripts: index == 4 ? [row, refused] : [row], text: text, processingSeconds: 0)
            }, deliver: { _, text in try probe.deliver(text) }, now: { probe.now }))
        service.highlightTargetField = false
        service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        service.cleanUpDictation = false
        service.speakers.peopleStore = try PeopleStore(sharing: store)
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let id = service.timeline.activeSessionID!
        service.library.showLive(id)
        func speak(_ index: Int) async {
            probe.now += 3
            service.ingestRecoveryVerification(samples: Array(repeating: Float(index), count: 48_000), at: probe.now)
            await service.waitForRecoveryVerification()
        }
        func shown() -> [String] {
            service.library.live.paragraphs.map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }
        func fullRead() async -> [String] {
            await service.library.sessionParagraphs(id).map { "\(TranscriptExport.speakerName($0)): \($0.text)" }
        }

        func checkShown(_ message: String, condition: () -> Bool = { true }) async {
            await service.library.waitForReads()
            let expected = await fullRead()
            precondition(condition() && shown() == expected, message)
        }

        for index in 1...4 {
            await speak(index)
        }
        await checkShown("Live lost a saved row when the next row of its block could not be saved", condition: { shown().last == "Speaker 2: segment4" })
        try await libraryMatchesStore(service, store, "a block whose second row could not be saved")
        let revision = service.library.live.revision
        service.library.showLive(id)
        precondition(service.library.live.revision == revision, "Live read its session again when it was shown a second time")
        service.dictation.begin()
        await speak(5)
        service.dictation.end()
        await service.waitForRecoveryVerification()
        await checkShown("Live did not show the session as saved", condition: { service.library.live.paragraphs.contains { $0.mode == "dictation" } })
        try await libraryMatchesStore(service, store, "a dictation held while listening")

        await service.labelSpeaker(session: id, speaker: "speaker-1", name: "Ada")
        await checkShown("Live kept the old name after a speaker was named", condition: { shown().contains("Ada: segment1") })
        service.notice = ""
        // A voice of zeros cannot be remembered. The name is saved before that fails.
        await service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace", voice: [0, 0])
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty, "Remembering a voice of zeros did not fail")
        await checkShown("Live kept the old name when remembering the voice failed", condition: { shown().contains("Grace: segment3") })
        let request = try JSONSerialization.data(withJSONObject: ["method": "speakers.label", "params": ["sessionID": id, "speakerID": "speaker-1", "name": "Ada King"]])
        let reply = try JSONSerialization.jsonObject(with: await service.handle(request)) as? [String: Any]
        precondition(reply?["ok"] as? Bool == true, "speakers.label failed over the socket")
        await checkShown("Live kept the old name after speakers.label", condition: { shown().contains("Ada King: segment1") })

        service.tuning.paragraphPause = 2.5
        await checkShown("Live kept the old paragraphs after a new paragraph pause", condition: { shown().contains("Ada King: segment1 segment2") })
        let paused = service.library.live.revision
        service.tuning.speakerConfidence = 0.8
        precondition(service.library.live.revision == paused, "Live read its session again after a setting it does not group by")
        try await service.deleteHistoryCard(service.library.history.first!)
        await checkShown("Live still showed a deleted row", condition: { !service.library.live.paragraphs.contains { $0.mode == "dictation" } })

        // Hiding the names table makes the session read fail. Live still moves to the session, so a row saved next shows, and the next reload reads the whole session.
        service.library.showLive(nil)
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.library.showLive(id)
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty && service.library.live.paragraphs.isEmpty, "Reading the session without its names table did not fail")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        await speak(6)
        precondition(service.library.live.paragraphs.map(\.text) == ["segment6"], "Live dropped a row saved after a failed read")
        await service.labelSpeaker(session: id, speaker: "speaker-2", name: "Grace Hopper")
        await checkShown("Live did not read the session again after a failed read", condition: { shown().contains("Ada King: segment1 segment2") })

        // A reload of the shown session that fails keeps what Live shows, and the next show reads the session again.
        let kept = shown()
        renameTable("speaker_labels", to: "hidden_labels", in: folder)
        service.notice = ""
        service.tuning.paragraphPause = 1.5
        await service.library.waitForReads()
        precondition(!service.notice.isEmpty && shown() == kept, "Live dropped its rows when a reload of the shown session failed")
        renameTable("hidden_labels", to: "speaker_labels", in: folder)
        service.library.showLive(id)
        await checkShown("Live did not read the session again after a failed reload", condition: { shown().contains("Ada King: segment1") })
        await speak(7)
        try await libraryMatchesStore(service, store, "speaker names, a delete and failed reads, then a block")
        print("PASS: Live keeps a row saved before a failed one, and reads its session again after a speaker name, a failed voice, speakers.label, a new paragraph pause, and a delete, but not after another setting or a second show.")
        print("PASS: after a failed switch Live shows the rows saved next; after a failed reload it keeps its rows; either way the next read retries.")
        print("PASS: recent rows, Sessions and Dictations take in each block's saved rows and cleaned text without a full read, and match one.")
        // A service reads its tuning from the settings when it is made, so later checks start from the defaults again.
        service.tuning = TranscriptionTuning()
        await service.library.waitForReads()
    }

    /// Recent rows, Sessions and Dictations fold in each block's saved rows and each phrase's cleaned text instead of reading the store again; what they hold must be what a full read returns.
    @MainActor static func libraryMatchesStore(_ service: SpeechService, _ store: TranscriptStore, _ step: String) async throws {
        await service.library.waitForReads()
        let recent = try store.recent(limit: 20), sessions = try store.sessions(limit: 200)
        precondition(service.library.recent == recent, "Recent rows differ from a full read after \(step)")
        precondition(service.library.sessions == sessions, "Sessions differ from a full read after \(step)")
        let history = service.library.history, count = service.library.dictationCount, more = service.library.hasMoreHistory
        service.library.refreshHistory()
        await service.library.waitForReads()
        precondition(service.library.history == history && service.library.dictationCount == count && service.library.hasMoreHistory == more,
            "Dictations differ from a full read after \(step)")
    }

    /// Renames a table of a store's database over a second connection, so the store's next query of it fails, or works again.
    static func renameTable(_ name: String, to newName: String, in folder: URL) {
        var db: OpaquePointer?
        let path = folder.appendingPathComponent("transcripts.sqlite3").path
        precondition(sqlite3_open(path, &db) == SQLITE_OK, "Could not open the store's database")
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        precondition(sqlite3_exec(db, "ALTER TABLE \(name) RENAME TO \(newName)", nil, nil, nil) == SQLITE_OK, "Could not rename \(name)")
    }
}
