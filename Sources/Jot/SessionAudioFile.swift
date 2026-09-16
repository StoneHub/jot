import Foundation
import JotCore

/// One ambient session's audio on disk, kept only until the speaker pass has read it. Writes run on a utility queue; the controller hands over each drained packet and moves on.
final class SessionAudioFile: @unchecked Sendable {
    struct Outcome: Sendable {
        let url: URL
        let durationSeconds: Double
        let truncated: Bool
    }
    /// Two hours of mono 16 kHz Float32; a longer session keeps its first two hours for the pass.
    static let byteLimit = AudioClock.samples(seconds: 7200) * MemoryLayout<Float>.size
    let sessionID: String
    let url: URL
    private let queue = DispatchQueue(label: "space.jot.session-audio", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0
    private var truncated = false
    private var failure: Error?

    init(sessionID: String) {
        self.sessionID = sessionID
        url = SessionAudioPaths.url(sessionID: sessionID)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { self.write(samples.withUnsafeBufferPointer { Data(buffer: $0) }) }
    }

    /// Zeros stand in for samples the capture queue dropped, so a position in the file stays equal to a session offset.
    func appendSilence(samples count: Int) {
        guard count > 0 else { return }
        queue.async { self.write(Data(count: count * MemoryLayout<Float>.size)) }
    }

    private func write(_ data: Data) {
        guard failure == nil, !truncated else { return }
        do {
            if handle == nil {
                try SessionAudioPaths.prepareDirectory()
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw JotError.message("Could not create the session audio file.")
                }
                handle = try FileHandle(forWritingTo: url)
            }
            let room = Self.byteLimit - bytes
            if data.count > room { truncated = true }
            let chunk = data.count > room ? data.prefix(room) : data
            try handle?.write(contentsOf: chunk)
            bytes += chunk.count
        } catch { failure = error; remove() }
    }

    /// Closes the file once every queued write is on disk. Nil when no audio arrived; throws the first write error, and nothing is left on disk then.
    func finish() async throws -> Outcome? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                try? self.handle?.close(); self.handle = nil
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                guard self.bytes > 0 else { self.remove(); continuation.resume(returning: nil); return }
                continuation.resume(returning: Outcome(url: self.url, durationSeconds: AudioClock.seconds(samples: self.bytes / MemoryLayout<Float>.size), truncated: self.truncated))
            }
        }
    }

    /// Deletes the file after any queued write, for a session that gets no pass.
    func discard() {
        queue.async { try? self.handle?.close(); self.handle = nil; self.remove() }
    }

    private func remove() { try? FileManager.default.removeItem(at: url) }

    /// Deletes the files an earlier run left behind and returns their session ids so each deletion is logged.
    static func discardStale(except sessionID: String) -> [String] {
        let stale = SessionAudioPaths.staleSessionIDs(except: sessionID)
        for id in stale { try? FileManager.default.removeItem(at: SessionAudioPaths.url(sessionID: id)) }
        return stale
    }
}
