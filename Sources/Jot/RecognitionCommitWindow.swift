import Foundation
import FluidAudio

/// Owns an append-only session clock for bounded ambient recognition. Two
/// seconds on each side of the commit cursor stay in RAM; adding the next
/// three-second capture block therefore gives ASR at most seven seconds.
struct RecognitionCommitWindow {
    private struct CommittedWord {
        let normalized: String
        let start: Double
        let end: Double
    }

    struct Plan {
        let samples: [Float]
        let bufferOffset: Double
        let commitStart: Double
        let commitEnd: Double
        let isFinal: Bool

        func contains(start: Double, end: Double) -> Bool {
            let midpoint = bufferOffset + (start + end) / 2
            return midpoint >= commitStart && (isFinal ? midpoint <= commitEnd : midpoint < commitEnd)
        }
    }

    private let sampleRate: Int
    private let leftContextSamples: Int
    private let uncommittedTailSamples: Int
    private var sessionID = ""
    private var samples: [Float] = []
    private var bufferOffset = 0.0
    private var expectedOffset = 0.0
    private var committedThrough = 0.0
    private var recentWords: [CommittedWord] = []

    init(contextSeconds: Double = 2, sampleRate: Int = AudioClock.sampleRate) {
        self.sampleRate = sampleRate
        leftContextSamples = max(0, Int((contextSeconds * Double(sampleRate)).rounded()))
        uncommittedTailSamples = leftContextSamples
    }

    mutating func plan(sessionID: String, offset: Double, newSamples: [Float], isFinal: Bool) -> Plan {
        if self.sessionID != sessionID || abs(offset - expectedOffset) > 0.02 {
            reset(sessionID: sessionID, offset: offset)
        }
        if samples.isEmpty { bufferOffset = offset }
        samples.append(contentsOf: newSamples)
        expectedOffset = offset + Double(newSamples.count) / Double(sampleRate)
        let end = bufferOffset + Double(samples.count) / Double(sampleRate)
        let tail = Double(uncommittedTailSamples) / Double(sampleRate)
        return Plan(samples: samples, bufferOffset: bufferOffset,
            commitStart: max(bufferOffset, committedThrough),
            commitEnd: isFinal ? end : max(committedThrough, end - tail), isFinal: isFinal)
    }

    /// Assigns words to this commit interval and removes only words that match
    /// a previously committed word at the same acoustic time. The timing check
    /// keeps genuinely repeated speech even when adjacent words are identical.
    mutating func newWords(from decodedWords: [WordTiming], for plan: Plan) -> [WordTiming] {
        decodedWords.filter { word in
            guard plan.contains(start: word.startTime, end: word.endTime) else { return false }
            let normalized = Self.normalize(word.word)
            guard !normalized.isEmpty else { return true }
            let start = plan.bufferOffset + word.startTime
            let end = plan.bufferOffset + word.endTime
            return !recentWords.contains { committed in
                committed.normalized == normalized
                    && max(committed.start, start) < min(committed.end, end)
            }
        }
    }

    mutating func commit(_ plan: Plan, words: [WordTiming] = []) {
        guard !plan.isFinal else { reset(); return }
        recentWords.append(contentsOf: words.compactMap { word in
            let normalized = Self.normalize(word.word)
            guard !normalized.isEmpty else { return nil }
            return CommittedWord(normalized: normalized,
                start: plan.bufferOffset + word.startTime,
                end: plan.bufferOffset + word.endTime)
        })
        committedThrough = plan.commitEnd
        let left = Double(leftContextSamples) / Double(sampleRate)
        let keepFrom = max(bufferOffset, committedThrough - left)
        let dropCount = min(samples.count, max(0,
            Int(((keepFrom - bufferOffset) * Double(sampleRate)).rounded())))
        if dropCount > 0 {
            samples.removeFirst(dropCount)
            bufferOffset += Double(dropCount) / Double(sampleRate)
        }
        recentWords.removeAll { $0.end <= keepFrom }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
        sessionID = ""
        bufferOffset = 0
        expectedOffset = 0
        committedThrough = 0
        recentWords.removeAll(keepingCapacity: false)
    }

    private mutating func reset(sessionID: String, offset: Double) {
        samples.removeAll(keepingCapacity: true)
        self.sessionID = sessionID
        bufferOffset = offset
        expectedOffset = offset
        committedThrough = offset
        recentWords.removeAll(keepingCapacity: true)
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }
}
