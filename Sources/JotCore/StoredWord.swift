import Foundation

/// One recognized word behind an ambient transcript row: its timing in the session's clock and the diarizer's four speaker probabilities. No audio.
public struct StoredWord: Codable, Sendable {
    public var transcriptID: String
    public var position: Int
    public var word: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var probabilities: [Float]
    public init(transcriptID: String, position: Int, word: String, startSeconds: Double, endSeconds: Double, probabilities: [Float]) {
        self.transcriptID = transcriptID; self.position = position; self.word = word
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.probabilities = probabilities
    }
}
