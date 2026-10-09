import Foundation
import JotCore

public struct SpeechOutput: Sendable {
    public let transcripts: [Transcript]
    public let text: String
    public let processingSeconds: Double
    /// The words each ambient transcript was built from, keyed by Transcript.id, with times relative to the job like AttributedWord.
    public var wordsByTranscript: [String: [AttributedWord]] = [:]
    /// The voice detector's highest speech probability over the recognition window; nil when it did not run.
    public var speechProbability: Float?

    public init(transcripts: [Transcript], text: String, processingSeconds: Double,
                wordsByTranscript: [String: [AttributedWord]] = [:], speechProbability: Float? = nil) {
        self.transcripts = transcripts
        self.text = text
        self.processingSeconds = processingSeconds
        self.wordsByTranscript = wordsByTranscript
        self.speechProbability = speechProbability
    }
}
