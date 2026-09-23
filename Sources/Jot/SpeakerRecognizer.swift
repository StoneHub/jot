import Foundation
import JotCore

/// What the recognizer needs from the service: the transcript store, the current tuning, and a place to report.
@MainActor
protocol SpeakerRecognizerHost: AnyObject {
    var store: TranscriptStore? { get }
    var tuning: TranscriptionTuning { get }
    var notice: String { get set }
    func sessionIsDeleted(_ id: String) -> Bool
    func recognitionIsComplete(for session: String) -> Bool
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

    /// The pass runs off the main actor; only its outcome lands here. An export that already happened used the live labels; the saved rows are rebuilt from the pass once the session's last audio block is recognized.
    private func run(_ file: SessionAudioFile) async {
        let id = file.sessionID
        passRunning = true
        defer { passRunning = false }
        do {
            guard let audio = try await file.finish() else { return }
            let result = SpeakerPassRelabel.renumbered(try await pass.run(url: audio.url))
            try await MeetingExportWait.wait(isValid: { true }, isComplete: { self.host.recognitionIsComplete(for: id) })
            guard !host.sessionIsDeleted(id) else { return }
            try speakerStore?.replace(sessionID: id, result: result)
            // The pass is authoritative: a name given to "speaker-2" while the live labels were showing stays on that id, which the pass may have given to another voice. Naming normally happens after the pass anyway.
            var recognized: [String] = []
            if let store = host.store, !result.segments.isEmpty, case let words = try store.words(sessionID: id), !words.isEmpty {
                try store.replaceSession(sessionID: id, words: words, turns: SpeakerPassRelabel.turns(words: words, segments: result.segments, tuning: host.tuning))
                recognized = try recognizeSpeakers(result.speakers, session: id)
                host.didRelabelSession()
            }
            let count = result.speakers.count
            let scope = audio.truncated ? " (first two hours)" : ""
            host.recordEvent(.speakerPass, "Speaker pass found \(count) speaker\(count == 1 ? "" : "s") in \(TranscriptExport.clock(result.durationSeconds)) of audio\(scope), \(String(format: "%.1f", result.processingSeconds)) s of processing.", duration: result.durationSeconds, session: id)
            host.notice = "Speaker pass finished: \(count) speakers" + (recognized.isEmpty ? "." : ", recognized \(recognized.joined(separator: ", ")).")
        } catch {
            host.recordEvent(.processingError, "Speaker pass: \(error.localizedDescription)", duration: nil, session: id)
            host.notice = "Speaker pass failed: \(error.localizedDescription)"
        }
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

    /// The speaker pass's voice embedding for one speaker of one session; nil before the pass or for a speaker it did not find.
    func passEmbedding(session: String, speaker: String) -> [Float]? {
        (try? speakerStore?.speakers(sessionID: session))?.first { $0.speakerID == speaker }?.embedding
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
