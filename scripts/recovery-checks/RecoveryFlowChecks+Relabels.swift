import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// What relabel speaker closures did, recorded from whichever thread runs them.
    final class RelabelLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var entries: [String] { lock.withLock { recorded } }
        func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    }

    /// Relabels of one session take turns and hold off Install Update. A Regroup whose session is deleted while it waits returns quietly, a pass whose session is deleted while it waits leaves nothing behind, a pass whose relabel fails partway and a Regroup both reload Live, Regroup of a session without words says so, the name sheet offers a pass voice only once the pass has relabeled the rows, and names typed before the pass follow their voices and are remembered.
    @MainActor static func checkRelabelsTakeTurns(directory: URL) async throws {
        let folder = directory.appendingPathComponent("relabel-turns")
        let store = try TranscriptStore(directory: folder)
        let service = SpeechService(dependencies: .init(
            infer: { _, _, _ in SpeechOutput(transcripts: [], text: "", processingSeconds: 0) },
            deliver: { _, _ in throw DictationInput.InputError.targetChanged },
            now: Date.init))
        service.keepAudioForSpeakerPass = false
        service.cleanUpTranscriptions = false
        let passStore = try SpeakerPassStore(sharing: store)
        service.speakers.speakerStore = passStore
        service.beginRecoveryVerification(store: store)
        defer { service.shutdown() }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        /// A finished one-row session of two words, stored directly.
        func seed(_ session: String) throws {
            let row = Transcript(sessionID: session, startedAt: started, startSeconds: 0, endSeconds: 1, text: "one two", mode: "ambient")
            try store.append(row)
            try store.appendWords([
                StoredWord(transcriptID: row.id, position: 0, word: "one", startSeconds: 0, endSeconds: 0.4, probabilities: []),
                StoredWord(transcriptID: row.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.9, probabilities: [])])
        }
        /// Starts a relabel of the session whose speakers wait for the gate, and returns once it holds the session's turn.
        func hold(_ session: String, gate: DispatchSemaphore, log: RelabelLog) async throws -> Task<Bool, Error> {
            let relabel = Task {
                try await service.library.relabel(session) { words in
                    log.append("held began")
                    gate.wait()
                    log.append("held ended")
                    return words.map { _ in "speaker-1" }
                }
            }
            while !log.entries.contains("held began") {
                try await Task.sleep(for: .milliseconds(5))
            }
            return relabel
        }
        func waitUntil(_ description: String, _ ready: () -> Bool) async throws {
            for _ in 0..<400 {
                if ready() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Timed out waiting for \(description)")
        }

        try seed("turns")
        await service.library.waitForReads()
        await service.library.storeExecutor.flush()
        precondition(service.canInstallUpdate, "Install Update was held off before any relabel")
        let screen = ServiceScreen(service)
        let gate = DispatchSemaphore(value: 0)
        let log = RelabelLog()
        let held = try await hold("turns", gate: gate, log: log)
        let next = Task {
            try await service.library.relabel("turns") { words in
                log.append("next")
                return words.map { _ in "speaker-2" }
            }
        }
        // Long enough for the next relabel to reach its speakers if nothing made it wait.
        try await Task.sleep(for: .milliseconds(300))
        precondition(!log.entries.contains("next"), "A second relabel of the session ran while the first held its turn: \(log.entries)")
        precondition(!service.canInstallUpdate, "Install Update was offered while a relabel was writing")
        try await screen.settle()
        precondition(!screen.update, "App replacement stayed allowed while a relabel was writing")
        gate.signal()
        _ = try await held.value
        _ = try await next.value
        precondition(log.entries == ["held began", "held ended", "next"], "The second relabel did not wait for the first: \(log.entries)")
        let labels = try store.session(id: "turns").map(\.speakerID)
        precondition(labels == ["speaker-2"], "The later relabel's speakers did not stay: \(labels)")
        await service.library.waitForReads()
        await service.library.storeExecutor.flush()
        precondition(service.canInstallUpdate, "Install Update stayed held off after the relabels finished")
        try await screen.settle()
        precondition(screen.update, "App replacement stayed blocked after the relabels finished")
        print("PASS: a second relabel of a session waits until the first has finished, the later one's speakers stay, and Install Update waits for both, on screen too.")

        // Regroup waits behind the held relabel; the session is deleted before its turn comes.
        try seed("regroup-deleted")
        let regroupGate = DispatchSemaphore(value: 0)
        let regroupLog = RelabelLog()
        let regroupBlocker = try await hold("regroup-deleted", gate: regroupGate, log: regroupLog)
        let regroup = Task { try await service.regroupSession("regroup-deleted") }
        try await Task.sleep(for: .milliseconds(50))
        let deleteRegroup = Task { try await service.deleteSession("regroup-deleted") }
        try await waitUntil("Regroup deletion intent") { service.library.pendingDeletionCount > 0 }
        regroupGate.signal()
        _ = try await regroupBlocker.value
        try await deleteRegroup.value
        do {
            try await regroup.value
        } catch {
            preconditionFailure("Regroup of a session deleted while it waited reported: \(error.localizedDescription)")
        }
        precondition(service.notice == "Session deleted.", "Regroup of a deleted session changed the notice to: \(service.notice)")
        print("PASS: Regroup of a session deleted while it waited returns quietly.")

        // The pass stores its segments off the main thread, so they can land after the session is deleted. Here they land again while the pass waits for its turn, and the pass must remove them.
        try seed("pass-deleted")
        let passGate = DispatchSemaphore(value: 0)
        let passLog = RelabelLog()
        let passBlocker = try await hold("pass-deleted", gate: passGate, log: passLog)
        let result = SpeakerPassResult(segments: [("S1", 0, 0.45), ("S2", 0.45, 1)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 1, processingSeconds: 0.1)
        let pendingBeforePass = service.library.storeExecutor.pendingCount
        let pass = Task { await service.speakers.apply(result, session: "pass-deleted", truncated: false) }
        try await waitUntil("queued pass replacement") { service.library.storeExecutor.pendingCount > pendingBeforePass }
        let deletePass = Task { try await service.deleteSession("pass-deleted") }
        try await waitUntil("pass deletion intent") { service.library.pendingDeletionCount > 0 }
        passGate.signal()
        _ = try await passBlocker.value
        try await deletePass.value
        await pass.value
        let leftSegments = try passStore.segments(sessionID: "pass-deleted")
        precondition(leftSegments.isEmpty, "A pass for a deleted session left \(leftSegments.count) segments behind")
        let leftEvents = try store.events(sessionID: "pass-deleted")
        precondition(leftEvents.isEmpty, "A pass for a deleted session recorded events: \(leftEvents.map(\.kind))")
        print("PASS: a speaker pass whose session is deleted while it waits removes the segments it stored and records nothing.")

        // A pass whose relabel fails partway still reloads Live: the row it already relabeled stays relabeled. The second row's words were stored out of order across two batches, so its first piece fails the store's word check.
        let greeting = Transcript(sessionID: "fails", startedAt: started, startSeconds: 0, endSeconds: 0.3, text: "hi", speakerID: "speaker-4", mode: "ambient")
        let reply = Transcript(sessionID: "fails", startedAt: started, startSeconds: 0.4, endSeconds: 2.2, text: "one two three", speakerID: "speaker-4", mode: "ambient")
        try store.append(greeting)
        try store.append(reply)
        try store.appendWords([
            StoredWord(transcriptID: greeting.id, position: 0, word: "hi", startSeconds: 0, endSeconds: 0.2, probabilities: []),
            StoredWord(transcriptID: reply.id, position: 0, word: "one", startSeconds: 1.0, endSeconds: 1.2, probabilities: [])])
        try store.appendWords([
            StoredWord(transcriptID: reply.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.7, probabilities: []),
            StoredWord(transcriptID: reply.id, position: 2, word: "three", startSeconds: 2.0, endSeconds: 2.2, probabilities: [])])
        service.library.showLive("fails")
        let failing = SpeakerPassResult(segments: [("S1", 0, 1.5), ("S2", 1.5, 3)], speakers: ["S1": [1], "S2": [2]], durationSeconds: 3, processingSeconds: 0.1)
        await service.speakers.apply(failing, session: "fails", truncated: false)
        precondition(service.notice.hasPrefix("Speaker pass failed"), "The relabel did not fail partway: \(service.notice)")
        await service.library.waitForReads()
        let shown = service.library.live.paragraphs.map(\.speakerID)
        precondition(shown == ["speaker-1", "speaker-4"], "Live kept showing rows the failed relabel had already changed: \(shown)")
        print("PASS: a speaker pass whose relabel fails partway still reloads Live with the rows it changed.")

        // Regroup reloads Live too. Live's probabilities point every word at the first speaker, so Regroup relabels the row the capture labeled speaker-4.
        let regrouped = Transcript(sessionID: "regroup-reloads", startedAt: started, startSeconds: 0, endSeconds: 1, text: "one two", speakerID: "speaker-4", mode: "ambient")
        try store.append(regrouped)
        try store.appendWords([
            StoredWord(transcriptID: regrouped.id, position: 0, word: "one", startSeconds: 0, endSeconds: 0.4, probabilities: [0.9, 0, 0, 0]),
            StoredWord(transcriptID: regrouped.id, position: 1, word: "two", startSeconds: 0.5, endSeconds: 0.9, probabilities: [0.9, 0, 0, 0])])
        service.library.showLive("regroup-reloads")
        try await service.regroupSession("regroup-reloads")
        await service.library.waitForReads()
        let regroupedLive = service.library.live.paragraphs.map(\.speakerID)
        precondition(regroupedLive == ["speaker-1"], "Live kept showing the speakers from before Regroup: \(regroupedLive)")
        print("PASS: Regroup reloads Live with the speakers it wrote.")

        // A session saved before words were kept cannot be regrouped, and Regroup says so.
        try store.append(Transcript(sessionID: "no-words", startedAt: started, startSeconds: 0, endSeconds: 1, text: "recorded before words were kept", mode: "ambient"))
        do {
            try await service.regroupSession("no-words")
            preconditionFailure("Regroup of a session without words reported nothing: \(service.notice)")
        } catch {
            let message = error.localizedDescription
            precondition(message == "This session was recorded before Jot kept word timings; it cannot be regrouped.", "Regroup of a session without words reported: \(message)")
        }
        print("PASS: Regroup of a session saved before words were kept says it cannot be regrouped.")

        // The pass stores its voices before it relabels the rows. While it waits its turn, a row still carries its live speaker id, which can name another voice in the pass, so the name sheet offers no voice to remember.
        try seed("voices")
        let voicesGate = DispatchSemaphore(value: 0)
        let voicesLog = RelabelLog()
        let voicesBlocker = try await hold("voices", gate: voicesGate, log: voicesLog)
        let voices = SpeakerPassResult(segments: [("S1", 0, 1)], speakers: ["S1": [1, 0]], durationSeconds: 1, processingSeconds: 0.1)
        let pendingBeforeVoices = service.library.storeExecutor.pendingCount
        let voicesPass = Task { await service.speakers.apply(voices, session: "voices", truncated: false) }
        try await waitUntil("queued voice pass") { service.library.storeExecutor.pendingCount > pendingBeforeVoices }
        let waiting = await service.speakers.passEmbedding(session: "voices", speaker: "speaker-1")
        precondition(waiting == nil, "The name sheet offered a pass voice before the pass relabeled the rows: \(String(describing: waiting))")
        voicesGate.signal()
        _ = try await voicesBlocker.value
        await voicesPass.value
        let relabeled = await service.speakers.passEmbedding(session: "voices", speaker: "speaker-1")
        precondition(relabeled != nil, "The name sheet offered no pass voice once the pass relabeled the rows: \(service.notice)")
        print("PASS: the name sheet offers a pass voice only once the pass has relabeled the session's rows.")

        // Names typed in Live, before the pass, follow their voices: Live numbered Ada and Grace the other way round from the pass. The pass remembers both voices, Ada's into the Ada it already knew. Its third voice sounds like Ada, but Ada is named in this session already, so it stays unnamed.
        let people = try PeopleStore(sharing: store)
        service.speakers.peopleStore = people
        _ = try people.add(name: "Ada", embedding: [1, 0])
        for (speaker, start, text) in [("speaker-2", 0.0, "ada"), ("speaker-1", 2.0, "grace"), ("speaker-3", 4.0, "echo")] {
            let row = Transcript(sessionID: "names", startedAt: started, startSeconds: start, endSeconds: start + 1, text: "\(text) \(text)", speakerID: speaker, mode: "ambient")
            try store.append(row)
            try store.appendWords([
                StoredWord(transcriptID: row.id, position: 0, word: text, startSeconds: start, endSeconds: start + 0.4, probabilities: []),
                StoredWord(transcriptID: row.id, position: 1, word: text, startSeconds: start + 0.5, endSeconds: start + 0.9, probabilities: [])])
        }
        await service.labelSpeaker(session: "names", speaker: "speaker-2", name: "Ada")
        await service.labelSpeaker(session: "names", speaker: "speaker-1", name: "Grace")
        let beforePass = try people.list().map(\.sampleCount)
        precondition(beforePass == [1], "Naming before the pass remembered a voice it did not have yet: \(beforePass)")
        let named = SpeakerPassResult(segments: [("S5", 0, 1.5), ("S2", 1.5, 3.5), ("S9", 3.5, 5)], speakers: ["S5": [1, 0], "S2": [0, 1], "S9": [1, 0.1]], durationSeconds: 5, processingSeconds: 0.1)
        await service.speakers.apply(named, session: "names", truncated: false)
        let namedRows = try store.session(id: "names").sorted { $0.startSeconds < $1.startSeconds }
        precondition(namedRows.map(\.speakerID) == ["speaker-1", "speaker-2", "speaker-3"], "The pass did not relabel the named session: \(namedRows.map(\.speakerID))")
        precondition(namedRows.map(\.speakerLabel) == ["Ada", "Grace", nil], "Names typed before the pass did not follow their voices: \(namedRows.map(\.speakerLabel)), \(service.notice)")
        let remembered = try people.list()
        precondition(remembered.map(\.name) == ["Ada", "Grace"] && remembered.map(\.sampleCount) == [2, 1], "The pass did not remember the voices named before it: \(remembered.map { "\($0.name) \($0.sampleCount)" })")
        precondition(service.speakers.people.map(\.name) == ["Ada", "Grace"], "People did not show the voices the pass remembered")
        print("PASS: names typed before the speaker pass follow their voices onto the pass's speakers, the pass remembers those voices, and a remembered voice is not given to a second speaker.")
    }
}
