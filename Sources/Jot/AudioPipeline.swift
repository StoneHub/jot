import Foundation
import JotCore

struct AudioJob: Sendable {
    let sessionID: String
    let startedAt: Date
    let offset: Double
    let samples: [Float]
    let ticket: UUID
    var isFinal = false
    var submittedUptime = ProcessInfo.processInfo.systemUptime
}

/// The one sample rate every buffer in the app uses; the recognizer models expect 16 kHz mono.
enum AudioClock {
    static let sampleRate = 16000
    static func samples(seconds: Double) -> Int { Int((seconds * Double(sampleRate)).rounded()) }
    static func seconds(samples: Int) -> Double { Double(samples) / Double(sampleRate) }
}

struct SpeechOutput: Sendable {
    let transcripts: [Transcript]
    let text: String
    let processingSeconds: Double
    /// The words each ambient transcript was built from, keyed by Transcript.id, with times relative to the job like AttributedWord.
    var wordsByTranscript: [String: [AttributedWord]] = [:]
}

enum JotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
