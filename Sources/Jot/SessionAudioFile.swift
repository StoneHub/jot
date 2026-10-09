import Foundation
import JotCore

/// One ambient session's audio for the offline speaker pass. The shared writer owns file I/O and bounded admission.
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
    private let writer: SessionAudioWriter

    /// `directory` is for the check harness, which keeps its files out of the service directory.
    init(sessionID: String, directory: URL = SessionAudioPaths.directory) {
        self.sessionID = sessionID
        url = SessionAudioPaths.url(sessionID: sessionID, in: directory)
        writer = SessionAudioWriter(url: url, byteLimit: Self.byteLimit)
    }

    func append(_ samples: [Float]) { writer.append(samples) }
    func appendSilence(samples count: Int) { writer.appendSilence(samples: count) }

    /// Throws instead of offering a discontinuous file to the pass when writes overflow or fail.
    func finish() async throws -> Outcome? {
        guard let result = try await writer.finish() else { return nil }
        return Outcome(url: url, durationSeconds: AudioClock.seconds(samples: result.bytes / MemoryLayout<Float>.size),
                       truncated: result.truncated)
    }

    func discard() { writer.discard() }

    /// Deletes the files an earlier run left behind and returns their session ids so each deletion is logged.
    static func discardStale(except sessionID: String) -> [String] {
        let stale = SessionAudioPaths.staleSessionIDs(except: sessionID)
        for id in stale { try? FileManager.default.removeItem(at: SessionAudioPaths.url(sessionID: id)) }
        return stale
    }
}
