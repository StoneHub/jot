import Foundation
import JotCore

struct SpeechOutput: Sendable {
    let transcripts: [Transcript]
    let text: String
    let processingSeconds: Double
    /// The words each ambient transcript was built from, keyed by Transcript.id, with times relative to the job like AttributedWord.
    var wordsByTranscript: [String: [AttributedWord]] = [:]
    /// The voice detector's highest speech probability over the recognition window; nil when it did not run.
    var speechProbability: Float?
}
