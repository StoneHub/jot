import Foundation
import JotCore

/// Runs the speaker pass over a finished session, names the voices Jot remembers, and keeps the People list.
@MainActor
final class SpeakerRecognizer: ObservableObject {
    var speakerStore: SpeakerPassStore?
    var peopleStore: PeopleStore?
    /// The user's own voice, learned from dictation holds and kept outside the database. See UserVoice.
    var userVoiceStore: UserVoiceStore?
    @Published private(set) var userVoice: UserVoice?
    /// Voices Jot remembers, for the People screen and for naming matching speakers after a pass.
    @Published private(set) var people: [Person] = []
    @Published private(set) var passRunning = false
    /// Passes run one at a time in session order; a pass survives a pause and finishes on its own.
    private var passQueue: Task<Void, Never>?
    private var pendingPasses = 0
    var hasPendingPasses: Bool { pendingPasses > 0 || !passesBeingApplied.isEmpty }
    /// Sessions whose pass voices are stored while their rows may still carry live speaker ids, which can name another voice in the pass: from storing the pass until its relabel ends.
    private var passesBeingApplied = Set<String>()
    /// Sessions whose pass relabel failed partway, so some rows still carry live speaker ids. A successful Regroup rewrites them all.
    private var partlyRelabeled = Set<String>()
    private let pass: SpeakerPass
    private unowned let service: SpeechService

    init(pass: SpeakerPass, service: SpeechService) {
        self.pass = pass
        self.service = service
    }

    func enqueuePass(_ file: SessionAudioFile) {
        let previous = passQueue
        pendingPasses += 1
        passQueue = Task {
            defer { pendingPasses -= 1 }
            await previous?.value; await run(file)
        }
    }

    /// The pass runs off the main actor; only its outcome lands here.
    private func run(_ file: SessionAudioFile) async {
        let id = file.sessionID
        passRunning = true
        defer { passRunning = false }
        do {
            guard let audio = try await file.finish() else { return }
            let raw = try await pass.run(url: audio.url)
            await apply(raw, session: id, truncated: audio.truncated)
        } catch {
            reportFailure(error, session: id)
        }
    }

    /// Stores a pass and relabels the session's rows from it; the relabel waits until the session's last audio block is recognized and its cleanup has landed. The store work runs off the main thread. An export that already happened used the live labels. Internal so the check harness can hand it a result.
    func apply(_ raw: SpeakerPassResult, session id: String, truncated: Bool) async {
        passesBeingApplied.insert(id)
        defer { passesBeingApplied.remove(id) }
        do {
            let result = SpeakerPassRelabel.renumbered(raw)
            guard !service.library.sessionIsDeleted(id) else { return }
            let passStore = speakerStore
            try await Task.detached(priority: .userInitiated) { try passStore?.replace(sessionID: id, result: result) }.value
            var recognized: [String] = []
            if !result.segments.isEmpty {
                recognized = try await relabelAndName(result, session: id)
            }
            if service.library.sessionIsDeleted(id) {
                // Deleted while the pass was being stored or waited to relabel: its segments may have landed after the delete.
                let store = service.library.store
                try? await Task.detached(priority: .userInitiated) { try store?.deleteSession(id: id) }.value
                return
            }
            let count = result.speakers.count
            let scope = truncated ? " (first two hours)" : ""
            service.recordEvent(.speakerPass, "Speaker pass found \(count) speaker\(count == 1 ? "" : "s") in \(TranscriptExport.clock(result.durationSeconds)) of audio\(scope), \(String(format: "%.1f", result.processingSeconds)) s of processing.", duration: result.durationSeconds, session: id)
            service.notice = "Speaker pass finished: \(count) speakers" + (recognized.isEmpty ? "." : ", recognized \(recognized.joined(separator: ", ")).")
        } catch {
            reportFailure(error, session: id)
        }
    }

    /// Relabels the session's rows from the pass, moves the names given so far onto the voices they belong to and remembers those voices, then names the voices Jot remembers. All of it writes to the store, so Live and Sessions reload once they are done, even when one step fails partway. Returns the names recognized.
    private func relabelAndName(_ result: SpeakerPassResult, session id: String) async throws -> [String] {
        defer { service.library.didDeleteHistory() }
        let tuning = service.tuning
        let segments = result.segments
        let store = service.library.store
        let carried = CarriedNames()
        let relabeled: Bool
        do {
            relabeled = try await service.library.relabel(id) { words in
                let speakers = SpeakerPassRelabel.speakers(words: words, segments: segments, tuning: tuning)
                // Names given before the pass sit on live speaker ids. They are read here, just before the rows change, so a name typed while the relabel waited its turn moves too.
                if let store, let names = try? store.labels(sessionID: id), !names.isEmpty, let before = try? store.speakerIDs(sessionID: id) {
                    carried.set(names, moved: SpeakerPassRelabel.carriedLabels(names, words: words, before: before, after: speakers))
                }
                return speakers
            }
        } catch {
            partlyRelabeled.insert(id)
            throw error
        }
        partlyRelabeled.remove(id)
        guard relabeled, !service.library.sessionIsDeleted(id) else { return [] }
        if let names = carried.value, let store {
            // A name typed while the rows were being written stays as typed; the sheet had no voice to offer for it.
            let typed = try store.labels(sessionID: id).filter { names.named[$0.key] != $0.value }
            try store.replaceLabels(sessionID: id, names.moved.merging(typed) { _, typed in typed })
            for (speaker, name) in names.moved where typed[speaker] == nil {
                guard let voice = result.speakers[speaker] else { continue }
                // One voice that cannot be remembered, such as one saved by an older speaker model, leaves the rest of the pass alone.
                do { try remember(name, voice: voice) }
                catch { service.recordEvent(.processingError, "Could not remember \(name)'s voice: \(error.localizedDescription)", duration: nil, session: id) }
            }
        }
        learnUserVoice(session: id, speakers: result.speakers)
        return try recognizeSpeakers(result.speakers, session: id)
    }

    /// The pass speaker heard most during the session's dictation holds is the user. Its voice joins the learned user
    /// voice, and the speaker is labeled You unless someone already named it. A session with no hold teaches nothing.
    private func learnUserVoice(session id: String, speakers: [String: [Float]]) {
        guard let store = service.library.store, let userVoiceStore else { return }
        do {
            guard let held = SuggestionContext.heldVoices(rows: try store.session(id: id))[id], held.heldSeconds >= 1,
                  let embedding = speakers[held.speakerID] else { return }
            userVoice = try userVoiceStore.learn(embedding, heldSeconds: held.heldSeconds)
            if try store.labels(sessionID: id)[held.speakerID] == nil {
                try store.label(sessionID: id, speakerID: held.speakerID, name: UserVoice.label)
            }
        } catch {
            service.recordEvent(.processingError, "Could not learn your voice: \(error.localizedDescription)", duration: nil, session: id)
        }
    }

    func loadUserVoice() { userVoice = userVoiceStore?.load() }

    /// Forgets the learned voice. Sessions already labeled You keep the label; the next dictations teach it again.
    func forgetUserVoice() {
        do {
            try userVoiceStore?.forget(); userVoice = nil
            service.notice = "Your voice is forgotten. Jot learns it again from your next dictations."
        } catch { service.notice = error.localizedDescription }
    }

    private func reportFailure(_ error: Error, session id: String) {
        service.recordEvent(.processingError, "Speaker pass: \(error.localizedDescription)", duration: nil, session: id)
        service.notice = "Speaker pass failed: \(error.localizedDescription)"
    }

    /// Names each unnamed session speaker whose voice matches a remembered person, and folds the session's embedding into that person so the voice improves over time. A name someone gave stays, and a person already named in the session is not given to a second voice. Returns the names recognized.
    private func recognizeSpeakers(_ speakers: [String: [Float]], session id: String) throws -> [String] {
        guard let store = service.library.store, let peopleStore else { return [] }
        let labels = try store.labels(sessionID: id)
        let named = Set(labels.values.map(PeopleMatcher.nameKey))
        let people = try peopleStore.list().filter { !named.contains(PeopleMatcher.nameKey($0.name)) }
        var unnamed = speakers.filter { labels[$0.key] == nil }
        var recognized: [String] = []
        // The user's own voice first: the nearest unnamed speaker within the threshold, one per session, unless the session
        // already has a You. Learned from holds only, so a match here does not feed the average.
        if let you = userVoice, you.trusted, !named.contains(PeopleMatcher.nameKey(UserVoice.label)),
           let nearest = unnamed.compactMap({ speaker, embedding in you.distance(to: embedding).map { (speaker, $0) } })
                .min(by: { ($0.1, $0.0) < ($1.1, $1.0) }), nearest.1 <= PeopleMatcher.threshold {
            try store.label(sessionID: id, speakerID: nearest.0, name: UserVoice.label)
            unnamed[nearest.0] = nil
            recognized.append(UserVoice.label)
        }
        for match in PeopleMatcher.assignments(speakers: unnamed, people: people) {
            guard let person = people.first(where: { $0.id == match.id }), let embedding = unnamed[match.speaker] else { continue }
            try store.label(sessionID: id, speakerID: match.speaker, name: person.name)
            try peopleStore.updateEmbedding(id: person.id, with: embedding)
            recognized.append(person.name)
        }
        if !recognized.isEmpty { refreshPeople() }
        return recognized
    }

    /// A pass is storing its segments or relabeling the session's rows; Regroup waits for it.
    func isApplyingPass(_ id: String) -> Bool { passesBeingApplied.contains(id) }

    /// A Regroup rewrote every row of the session, so rows no longer mix live and pass speaker ids.
    func didRegroup(_ id: String) { partlyRelabeled.remove(id) }

    /// The pass's segments for one session, for regrouping its rows; empty when no pass has run.
    func segments(sessionID: String) throws -> [(speaker: String, start: Double, end: Double)] {
        try speakerStore?.segments(sessionID: sessionID).map { ($0.speakerID, $0.start, $0.end) } ?? []
    }

    /// Names one speaker in one session. With the pass's voice, the name is also remembered. Without it, the pass remembers the voice when it lands.
    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]?) throws {
        try service.library.store?.label(sessionID: session, speakerID: speaker, name: name); service.library.refreshRecent()
        if let voice { try remember(name, voice: voice) }
    }

    /// The voice joins the person of that name, or starts a new one. You is not a person: that voice is learned from holds.
    private func remember(_ name: String, voice: [Float]) throws {
        guard let peopleStore else { return }
        let key = PeopleMatcher.nameKey(name)
        guard key != PeopleMatcher.nameKey(UserVoice.label) else { return }
        if let person = try peopleStore.list().first(where: { PeopleMatcher.nameKey($0.name) == key }) { try peopleStore.updateEmbedding(id: person.id, with: voice) }
        else { try peopleStore.add(name: name, embedding: voice) }
        refreshPeople()
    }

    /// The speaker pass's voice embedding for one speaker of one session; nil before the pass, while the pass is relabeling the session's rows, after its relabel failed partway, or for a speaker it did not find.
    func passEmbedding(session: String, speaker: String) -> [Float]? {
        guard !passesBeingApplied.contains(session), !partlyRelabeled.contains(session) else { return nil }
        return (try? speakerStore?.speakers(sessionID: session))?.first { $0.speakerID == speaker }?.embedding
    }

    func refreshPeople() {
        do { people = try peopleStore?.list() ?? [] } catch { service.notice = error.localizedDescription }
    }

    func renamePerson(_ id: String, name: String) {
        do { try peopleStore?.rename(id: id, name: name); refreshPeople() } catch { service.notice = error.localizedDescription }
    }

    /// Forgets the voice only; names already written into sessions stay.
    func deletePerson(_ id: String) {
        do { try peopleStore?.delete(id: id); refreshPeople(); service.notice = "Person deleted. Their voice is forgotten." } catch { service.notice = error.localizedDescription }
    }
}

/// The names a relabel read and where it moved them, worked out on the relabel queue and read on the main actor once it finishes.
private final class CarriedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (named: [String: String], moved: [String: String])?
    var value: (named: [String: String], moved: [String: String])? { lock.withLock { stored } }
    func set(_ named: [String: String], moved: [String: String]) { lock.withLock { stored = (named, moved) } }
}
