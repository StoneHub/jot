import Foundation
import JotCore

/// What the listening timeline needs from the service: whether it is listening, the speaker-pass and quiet settings, the audio counters it updates, the recognition queue it feeds, and a place to report gaps.
@MainActor
protocol ListeningTimelineHost: AnyObject {
    var dependencies: SpeechServiceDependencies { get }
    var ambientEnabled: Bool { get }
    var keepAudioForSpeakerPass: Bool { get }
    var newSessionAfterSilence: Int { get }
    var lastAudioAt: Date? { get set }
    var droppedSeconds: Double { get set }
    var notice: String { get set }
    var jobs: [AudioJob] { get set }
    func recordEvent(_ kind: CaptureEventKind, _ detail: String, duration: Double?, session: String?)
    func markDictationGap(_ recoveryNotice: String)
    func enqueueSpeakerPass(_ file: SessionAudioFile)
    func refreshSessions()
}

/// The session continuous listening feeds: its id and clock, the audio not yet cut into recognition chunks, and the session's audio file for the speaker pass.
@MainActor
final class ListeningTimeline: ObservableObject {
    @Published private(set) var activeSessionID: String?
    private(set) var sessionID = UUID().uuidString
    /// Wall-clock start of the current ambient session; Live counts elapsed time from it.
    private(set) var sessionStarted = Date()
    /// When this session last produced a row, so a quiet stretch can be measured.
    var lastAmbientRowAt: Date?
    private(set) var ambientOffset = 0.0
    private var ambient: [Float] = []
    /// The session's audio on disk for the speaker pass; nil while no ambient session runs.
    private var sessionAudio: SessionAudioFile?
    private var consecutiveSilentSamples = 0
    /// Shorter audio is dropped: recognition on it is noise.
    private static let minimumJobSamples = AudioClock.samples(seconds: 0.2)
    private let chunkScheduler = CaptureChunkScheduler(sampleRate: AudioClock.sampleRate,
        maximumSeconds: 3, minimumSeconds: 0.2, silenceSeconds: 0.7)
    private unowned let host: ListeningTimelineHost

    init(host: ListeningTimelineHost) { self.host = host }

    /// Audio received but not yet cut into a recognition chunk.
    var bufferedSampleCount: Int { ambient.count }

    /// Starts a new session on the listening timeline: a fresh id and clock, an empty buffer, and an audio file for the speaker pass when it keeps audio.
    func beginSession(at start: Date, withAudio: Bool = true) {
        sessionID = UUID().uuidString; sessionStarted = start; ambientOffset = 0; activeSessionID = sessionID
        ambient = []; consecutiveSilentSamples = 0; lastAmbientRowAt = nil
        if withAudio, host.keepAudioForSpeakerPass { sessionAudio = SessionAudioFile(sessionID: sessionID) }
    }

    func ingestAudio(samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
        guard !samples.isEmpty || dropped > 0 else { return }
        host.lastAudioAt = lastAudio
        if dropped > 0 {
            let lostSeconds = AudioClock.seconds(samples: dropped + ambient.count)
            host.droppedSeconds += lostSeconds
            host.recordEvent(.audioGap, "Capture queue overflow discarded audio.", duration: lostSeconds, session: nil)
            // End attribution continuity rather than silently stitching across lost audio.
            ambientOffset += AudioClock.seconds(samples: ambient.count + dropped); ambient = []
            sessionAudio?.appendSilence(samples: dropped)
            host.notice = "Audio backlog overflow: a gap was recorded."
            host.markDictationGap("Some microphone audio was lost before recognition. Saved dictation remains available to retry.")
        }
        if host.ambientEnabled {
            ambient.append(contentsOf: samples)
            sessionAudio?.append(samples)
            consecutiveSilentSamples = rms < 0.002 ? consecutiveSilentSamples + samples.count : 0
            // Enqueue every complete bounded block, retaining the tail. A silence can
            // close the tail early so sentence delivery usually beats the hard limit.
            while ambient.count >= chunkScheduler.maximumSamples {
                flushAmbient(sampleCount: chunkScheduler.maximumSamples)
            }
            if chunkScheduler.shouldFlush(bufferedSamples: ambient.count,
                consecutiveSilentSamples: consecutiveSilentSamples) { flushAmbient(final: true) }
        }
    }

    /// The normal end and an automatic pause run the pass, since Resume starts a new session and this one is complete. The Pause button discards the file along with the rest of its unfinished audio.
    /// Capture keeps running; only the session it feeds changes, so the speaker pass and Live both start fresh on the next speech.
    func rotateSession() {
        let spoken = lastAmbientRowAt != nil
        flushAmbient(final: true)
        if spoken { host.recordEvent(.sessionSplit, "New session started after \(host.newSessionAfterSilence) minutes of quiet.", duration: nil, session: nil) }
        endSessionAudio(runPass: spoken)
        beginSession(at: host.dependencies.now())
        host.refreshSessions()
    }

    func endSessionAudio(runPass: Bool) {
        guard let file = sessionAudio else { return }
        sessionAudio = nil
        guard runPass else { file.discard(); return }
        host.enqueueSpeakerPass(file)
    }

    /// Switching the speaker pass off deletes the running session's file.
    func discardSessionAudio() { sessionAudio?.discard(); sessionAudio = nil }

    func flushAmbient(sampleCount: Int? = nil, final: Bool = false) {
        guard !ambient.isEmpty || final else { return }
        let count = min(sampleCount ?? ambient.count, ambient.count)
        let samples = Array(ambient.prefix(count))
        ambient.removeFirst(count)
        if ambient.isEmpty { consecutiveSilentSamples = 0 }
        let start = ambientOffset; ambientOffset += AudioClock.seconds(samples: samples.count)
        guard final || samples.count >= Self.minimumJobSamples else { return }
        if host.jobs.count >= 40 && !final {
            host.droppedSeconds += AudioClock.seconds(samples: samples.count)
            host.recordEvent(.audioGap, "Inference queue full; segment discarded.", duration: AudioClock.seconds(samples: samples.count), session: nil)
            host.notice = "Inference fell behind; bounded audio queue dropped a segment."
            host.markDictationGap("Dictation is partially saved, but an inference backlog caused an audio gap. Retry only after reviewing it.")
            return
        }
        host.jobs.append(AudioJob(sessionID: sessionID, startedAt: sessionStarted, offset: start, samples: samples, ticket: UUID(), isFinal: final))
    }
}
