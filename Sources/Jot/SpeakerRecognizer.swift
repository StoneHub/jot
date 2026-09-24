import Foundation
import JotCore

/// What the recognizer needs from the service: the transcript store, the current tuning, the relabel it runs after a pass, and a place to report.
@MainActor
protocol SpeakerRecognizerHost: AnyObject {
    var store: TranscriptStore? { get }
    var tuning: TranscriptionTuning { get }
    var notice: String { get set }
    func sessionIsDeleted(_ id: String) -> Bool
    func relabel(_ id: String, speakers: @escaping @Sendable ([StoredWord]) -> [String?]) async throws -> Bool
    func recordEvent(_ kind: CaptureEventKind, _ detail: String, duration: Double?, session: String?)
    func didRelabelSession()
    func refreshRecent()
}

/// Runs the speaker pass over a finished session, names the voices Jot remembers, and keeps the People list.
@MainActor
final class SpeakerRecognizer: ObservableObject {
    var speakerStore: SpeakerPassStore?
    var peopleStore: PeopleStore?
    /// Voices Jot remembers, for the People screen and for naming matching speakers after a pass.
    @Published private(set) var people: [Person] = []
    @Published private(set) var passRunning = false
    /// Passes run one at a time in session order; a pass survives a pause and finishes on its own.
    private var passQueue: Task<Void, Never>?
    /// Sessions whose pass voices are stored while their rows may still carry live speaker ids, which can name another voice in the pass: from storing the pass until its relabel ends.
    private var passesBeingApplied = Set<String>()
    private let pass: SpeakerPass
    private unowned let host: SpeakerRecognizerHost

    init(pass: SpeakerPass, host: SpeakerRecognizerHost) {
        self.pass = pass
        self.host = host
    }

    func enqueuePass(_ file: SessionAudioFile) {
        let previous = passQueue
        passQueue = Task { await previous?.value; await run(file) }
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
            guard !host.sessionIsDeleted(id) else { return }
            let passStore = speakerStore
            try await Task.detached(priority: .userInitiated) { try passStore?.replace(sessionID: id, result: result) }.value
            var recognized: [String] = []
            if !result.segments.isEmpty {
                recognized = try await relabelAndName(result, session: id)
            }
            if host.sessionIsDeleted(id) {
                // Deleted while the pass was being stored or waited to relabel: its segments may have landed after the delete.
                let store = host.store
                try? await Task.detached(priority: .userInitiated) { try store?.deleteSession(id: id) }.value
                return
            }
            let count = result.speakers.count
            let scope = truncated ? " (first two hours)" : ""
            host.recordEvent(.speakerPass, "Speaker pass found \(count) speaker\(count == 1 ? "" : "s") in \(TranscriptExport.clock(result.durationSeconds)) of audio\(scope), \(String(format: "%.1f", result.processingSeconds)) s of processing.", duration: result.durationSeconds, session: id)
            host.notice = "Speaker pass finished: \(count) speakers" + (recognized.isEmpty ? "." : ", recognized \(recognized.joined(separator: ", ")).")
        } catch {
            reportFailure(error, session: id)
        }
    }

    /// Relabels the session's rows from the pass, then names the voices Jot remembers. Both write to the store, so Live and Sessions reload once they are done, even when one fails partway. Returns the names recognized.
    private func relabelAndName(_ result: SpeakerPassResult, session id: String) async throws -> [String] {
        defer { host.didRelabelSession() }
        let tuning = host.tuning
        let segments = result.segments
        let relabeled = try await host.relabel(id) { SpeakerPassRelabel.speakers(words: $0, segments: segments, tuning: tuning) }
        guard relabeled, !host.sessionIsDeleted(id) else { return [] }
        // The pass is authoritative: a name given to "speaker-2" while the live labels were showing stays on that id, which the pass may have given to another voice. Naming normally happens after the pass anyway.
        return try recognizeSpeakers(result.speakers, session: id)
    }

    private func reportFailure(_ error: Error, session id: String) {
        host.recordEvent(.processingError, "Speaker pass: \(error.localizedDescription)", duration: nil, session: id)
        host.notice = "Speaker pass failed: \(error.localizedDescription)"
    }

    /// Names each session speaker whose voice matches a remembered person, unless the speaker was named already, and folds the session's embedding into that person so the voice improves over time. Returns the names recognized.
    private func recognizeSpeakers(_ speakers: [String: [Float]], session id: String) throws -> [String] {
        guard let store = host.store, let peopleStore else { return [] }
        let people = try peopleStore.list()
        let labels = try store.labels(sessionID: id)
        var recognized: [String] = []
        for match in PeopleMatcher.assignments(speakers: speakers, people: people) {
            guard let person = people.first(where: { $0.id == match.id }), let embedding = speakers[match.speaker] else { continue }
            if labels[match.speaker] == nil { try store.label(sessionID: id, speakerID: match.speaker, name: person.name) }
            try peopleStore.updateEmbedding(id: person.id, with: embedding)
            recognized.append(person.name)
        }
        if !recognized.isEmpty { refreshPeople() }
        return recognized
    }

    /// The pass's segments for one session, for regrouping its rows; empty when no pass has run.
    func segments(sessionID: String) throws -> [(speaker: String, start: Double, end: Double)] {
        try speakerStore?.segments(sessionID: sessionID).map { ($0.speakerID, $0.start, $0.end) } ?? []
    }

    /// Names one speaker in one session. With a voice, the name is also remembered: the embedding joins the person of that name, or starts a new one.
    func labelSpeaker(session: String, speaker: String, name: String, voice: [Float]?) throws {
        try host.store?.label(sessionID: session, speakerID: speaker, name: name); host.refreshRecent()
        guard let voice, let peopleStore else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let person = try peopleStore.list().first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { try peopleStore.updateEmbedding(id: person.id, with: voice) }
        else { try peopleStore.add(name: trimmed, embedding: voice) }
        refreshPeople()
    }

    /// The speaker pass's voice embedding for one speaker of one session; nil before the pass, while the pass is relabeling the session's rows, or for a speaker it did not find.
    func passEmbedding(session: String, speaker: String) -> [Float]? {
        guard !passesBeingApplied.contains(session) else { return nil }
        return (try? speakerStore?.speakers(sessionID: session))?.first { $0.speakerID == speaker }?.embedding
    }

    func refreshPeople() {
        do { people = try peopleStore?.list() ?? [] } catch { host.notice = error.localizedDescription }
    }

    func renamePerson(_ id: String, name: String) {
        do { try peopleStore?.rename(id: id, name: name); refreshPeople() } catch { host.notice = error.localizedDescription }
    }

    /// Forgets the voice only; names already written into sessions stay.
    func deletePerson(_ id: String) {
        do { try peopleStore?.delete(id: id); refreshPeople(); host.notice = "Person deleted. Their voice is forgotten." } catch { host.notice = error.localizedDescription }
    }
}
