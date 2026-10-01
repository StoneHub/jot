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
    /// Queued pass and People work retain the owner until completion; nothing is read through it.
    private unowned let owner: AnyObject
    private let library: SessionLibrary
    private let settings: JotSettings
    private let recordEvent: (CaptureEventKind, String, Double?, String?) -> Void
    private let setNotice: (String) -> Void
    private var peopleRevision = 0
    private var voiceRevision = 0

    init(pass: SpeakerPass, owner: AnyObject, library: SessionLibrary, settings: JotSettings,
         recordEvent: @escaping (CaptureEventKind, String, Double?, String?) -> Void,
         setNotice: @escaping (String) -> Void) {
        self.pass = pass
        self.owner = owner
        self.library = library
        self.settings = settings
        self.recordEvent = recordEvent
        self.setNotice = setNotice
    }

    func enqueuePass(_ file: SessionAudioFile) {
        let previous = passQueue
        let owner = owner
        pendingPasses += 1
        // Deferred work that often starts after a quiet stretch; utility keeps it off the cores the foreground app is using.
        passQueue = Task(priority: .utility) {
            defer {
                withExtendedLifetime(owner) {}
                pendingPasses -= 1
                if pendingPasses == 0 { passQueue = nil }
            }
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
            guard !(await library.waitForDeletion(id)) else { return }
            let passStore = speakerStore
            try await library.storeExecutor.submit { try passStore?.replace(sessionID: id, result: result) }.value
            guard !(await library.waitForDeletion(id)) else { return }
            var recognized: [String] = []
            if !result.segments.isEmpty {
                recognized = try await relabelAndName(result, session: id)
            }
            guard !(await library.waitForDeletion(id)) else { return }
            let count = result.speakers.count
            let scope = truncated ? " (first two hours)" : ""
            recordEvent(.speakerPass, "Speaker pass found \(count) speaker\(count == 1 ? "" : "s") in \(TranscriptExport.clock(result.durationSeconds)) of audio\(scope), \(String(format: "%.1f", result.processingSeconds)) s of processing.", result.durationSeconds, id)
            setNotice("Speaker pass finished: \(count) speakers" + (recognized.isEmpty ? "." : ", recognized \(recognized.joined(separator: ", "))."))
        } catch {
            if await library.waitForDeletion(id) { return }
            reportFailure(error, session: id)
        }
    }

    /// Relabels the session's rows from the pass, moves the names given so far onto the voices they belong to and remembers those voices, then names the voices Jot remembers. All of it writes to the store, so Live and Sessions reload once they are done, even when one step fails partway. Returns the names recognized.
    private func relabelAndName(_ result: SpeakerPassResult, session id: String) async throws -> [String] {
        defer { library.didDeleteHistory() }
        let tuning = settings.tuning
        let segments = result.segments
        let store = library.store
        let carried = CarriedNames()
        let relabeled: Bool
        do {
            relabeled = try await library.relabel(id) { words in
                let speakers = SpeakerPassRelabel.speakers(words: words, segments: segments, tuning: tuning)
                // Names given before the pass sit on live speaker ids. They are read here, just before the rows change, so a name typed while the relabel waited its turn moves too.
                if let store, let names = try? store.labels(sessionID: id), !names.isEmpty, let before = try? store.speakerIDs(sessionID: id) {
                    carried.set(names, moved: SpeakerPassRelabel.carriedLabels(names, words: words, before: before, after: speakers))
                }
                return speakers
            }
        } catch {
            if await library.waitForDeletion(id) { return [] }
            partlyRelabeled.insert(id)
            throw error
        }
        partlyRelabeled.remove(id)
        guard relabeled, !(await library.waitForDeletion(id)) else { return [] }
        if let names = carried.value, let store {
            guard !(await library.waitForDeletion(id)) else { return [] }
            // A name typed while the rows were being written stays as typed; the sheet had no voice to offer for it.
            let typed = try await library.storeExecutor.submit {
                let typed = try store.labels(sessionID: id).filter { names.named[$0.key] != $0.value }
                try store.replaceLabels(sessionID: id, names.moved.merging(typed) { _, typed in typed })
                return typed
            }.value
            guard !(await library.waitForDeletion(id)) else { return [] }
            for (speaker, name) in names.moved where typed[speaker] == nil {
                guard !(await library.waitForDeletion(id)) else { return [] }
                guard let voice = result.speakers[speaker] else { continue }
                // One voice that cannot be remembered, such as one saved by an older speaker model, leaves the rest of the pass alone.
                do { try await remember(name, voice: voice) }
                catch { recordEvent(.processingError, "Could not remember \(name)'s voice: \(error.localizedDescription)", nil, id) }
            }
        }
        guard !(await library.waitForDeletion(id)) else { return [] }
        await learnUserVoice(session: id, speakers: result.speakers)
        guard !(await library.waitForDeletion(id)) else { return [] }
        return try await recognizeSpeakers(result.speakers, session: id)
    }

    /// The pass speaker heard most during the session's dictation holds is the user. Its voice joins the learned user
    /// voice, and the speaker is labeled You unless someone already named it. A session with no hold teaches nothing.
    private func learnUserVoice(session id: String, speakers: [String: [Float]]) async {
        guard let store = library.store, let userVoiceStore else { return }
        do {
            guard !(await library.waitForDeletion(id)) else { return }
            voiceRevision &+= 1
            let revision = voiceRevision
            let learned = try await library.storeExecutor.submit { () -> UserVoice? in
                guard let held = SuggestionContext.heldVoices(rows: try store.session(id: id))[id], held.heldSeconds >= 1,
                      let embedding = speakers[held.speakerID] else { return nil }
                let voice = try userVoiceStore.learn(embedding, heldSeconds: held.heldSeconds)
                if try store.labels(sessionID: id)[held.speakerID] == nil {
                    try store.label(sessionID: id, speakerID: held.speakerID, name: UserVoice.label)
                }
                return voice
            }.value
            guard !(await library.waitForDeletion(id)) else { return }
            if let learned, revision == voiceRevision { userVoice = learned }
        } catch {
            if await library.waitForDeletion(id) { return }
            recordEvent(.processingError, "Could not learn your voice: \(error.localizedDescription)", nil, id)
        }
    }

    func loadUserVoice() {
        let store = userVoiceStore
        let owner = owner
        voiceRevision &+= 1
        let revision = voiceRevision
        let operation = library.storeExecutor.submit { store?.load() }
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            let voice = try? await operation.value
            if revision == voiceRevision { userVoice = voice ?? nil }
        }
    }

    /// Forgets the learned voice. Sessions already labeled You keep the label; the next dictations teach it again.
    func forgetUserVoice() {
        let store = userVoiceStore
        let owner = owner
        voiceRevision &+= 1
        let revision = voiceRevision
        let operation = library.storeExecutor.submit { try store?.forget() }
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do {
                try await operation.value
                if revision == voiceRevision { userVoice = nil }
                setNotice("Your voice is forgotten. Jot learns it again from your next dictations.")
            } catch { setNotice(error.localizedDescription) }
        }
    }

    private func reportFailure(_ error: Error, session id: String) {
        recordEvent(.processingError, "Speaker pass: \(error.localizedDescription)", nil, id)
        setNotice("Speaker pass failed: \(error.localizedDescription)")
    }

    /// Names each unnamed session speaker whose voice matches a remembered person, and folds the session's embedding into that person so the voice improves over time. A name someone gave stays, and a person already named in the session is not given to a second voice. Returns the names recognized.
    private func recognizeSpeakers(_ speakers: [String: [Float]], session id: String) async throws -> [String] {
        guard let store = library.store, let peopleStore else { return [] }
        guard !(await library.waitForDeletion(id)) else { return [] }
        let learnedVoice = userVoice
        let recognized = try await library.storeExecutor.submit { () -> [String] in
            let labels = try store.labels(sessionID: id)
            let named = Set(labels.values.map(PeopleMatcher.nameKey))
            let people = try peopleStore.list().filter { !named.contains(PeopleMatcher.nameKey($0.name)) }
            var unnamed = speakers.filter { labels[$0.key] == nil }
            var recognized: [String] = []
            // A trusted held voice is named first, but never folded into a person's average.
            if let you = learnedVoice, you.trusted, !named.contains(PeopleMatcher.nameKey(UserVoice.label)),
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
            return recognized
        }.value
        guard !(await library.waitForDeletion(id)) else { return [] }
        if !recognized.isEmpty { refreshPeople() }
        return recognized
    }

    /// A pass is storing its segments or relabeling the session's rows; Regroup waits for it.
    func isApplyingPass(_ id: String) -> Bool { passesBeingApplied.contains(id) }

    /// A Regroup rewrote every row of the session, so rows no longer mix live and pass speaker ids.
    func didRegroup(_ id: String) { partlyRelabeled.remove(id) }

    /// The pass's segments for one session, for regrouping its rows; empty when no pass has run.
    func segments(sessionID: String) async throws -> [(speaker: String, start: Double, end: Double)] {
        guard !(await library.waitForDeletion(sessionID)) else { return [] }
        let store = speakerStore
        let segments = try await library.storeExecutor.submit {
            try store?.segments(sessionID: sessionID).map { ($0.speakerID, $0.start, $0.end) } ?? []
        }.value
        return await library.waitForDeletion(sessionID) ? [] : segments
    }

    /// Names one speaker in one session. With the pass's voice, the name is also remembered. Without it, the pass remembers the voice when it lands.
    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]?) async throws {
        guard !(await library.waitForDeletion(session)) else { return }
        let store = library.store
        try await library.storeExecutor.submit { try store?.label(sessionID: session, speakerID: speaker, name: name) }.value
        guard !(await library.waitForDeletion(session)) else { return }
        library.refreshRecent()
        if let voice { try await remember(name, voice: voice) }
    }

    /// The voice joins the person of that name, or starts a new one. You is not a person: that voice is learned from holds.
    private func remember(_ name: String, voice: [Float]) async throws {
        guard let peopleStore else { return }
        let key = PeopleMatcher.nameKey(name)
        guard key != PeopleMatcher.nameKey(UserVoice.label) else { return }
        try await library.storeExecutor.submit {
            if let person = try peopleStore.list().first(where: { PeopleMatcher.nameKey($0.name) == key }) {
                try peopleStore.updateEmbedding(id: person.id, with: voice)
            } else { try peopleStore.add(name: name, embedding: voice) }
        }.value
        refreshPeople()
    }

    /// The speaker pass's voice embedding for one speaker of one session; nil before the pass, while the pass is relabeling the session's rows, after its relabel failed partway, or for a speaker it did not find.
    func passEmbedding(session: String, speaker: String) async -> [Float]? {
        guard !passesBeingApplied.contains(session), !partlyRelabeled.contains(session),
              !(await library.waitForDeletion(session)) else { return nil }
        let store = speakerStore
        let found = try? await library.storeExecutor.submit {
            try store?.speakers(sessionID: session).first { $0.speakerID == speaker }?.embedding
        }.value
        guard !passesBeingApplied.contains(session), !partlyRelabeled.contains(session),
              !(await library.waitForDeletion(session)) else { return nil }
        return found ?? nil
    }

    func refreshPeople() {
        let store = peopleStore
        let owner = owner
        peopleRevision &+= 1
        let revision = peopleRevision
        let operation = library.storeExecutor.submit { try store?.list() ?? [] }
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do {
                let next = try await operation.value
                if revision == peopleRevision { people = next }
            } catch { setNotice(error.localizedDescription) }
        }
    }

    func renamePerson(_ id: String, name: String) {
        let store = peopleStore
        let owner = owner
        peopleRevision &+= 1
        let revision = peopleRevision
        let operation = library.storeExecutor.submit { () -> [Person] in
            try store?.rename(id: id, name: name)
            return try store?.list() ?? []
        }
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do {
                let next = try await operation.value
                if revision == peopleRevision { people = next }
            } catch { setNotice(error.localizedDescription) }
        }
    }

    /// Forgets the voice only; names already written into sessions stay.
    func deletePerson(_ id: String) {
        let store = peopleStore
        let owner = owner
        peopleRevision &+= 1
        let revision = peopleRevision
        let operation = library.storeExecutor.submit { () -> [Person] in
            try store?.delete(id: id)
            return try store?.list() ?? []
        }
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do {
                let next = try await operation.value
                if revision == peopleRevision { people = next }
                setNotice("Person deleted. Their voice is forgotten.")
            } catch { setNotice(error.localizedDescription) }
        }
    }
}

/// The names a relabel read and where it moved them, worked out on the relabel queue and read on the main actor once it finishes.
private final class CarriedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (named: [String: String], moved: [String: String])?
    var value: (named: [String: String], moved: [String: String])? { lock.withLock { stored } }
    func set(_ named: [String: String], moved: [String: String]) { lock.withLock { stored = (named, moved) } }
}
