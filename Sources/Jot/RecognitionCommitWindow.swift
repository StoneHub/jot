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
    /// Words the last decode heard after its commit end, on the session clock. The next decode owns that time
    /// but can miss them, most often at the start of its interval; they fill only where it heard nothing (#215).
    private var heldTail: [WordTiming] = []
    /// The same word this close to a held word is one word whose timing moved between decodes.
    private static let movedWordSeconds = 0.5
    /// A held word fills only a gap at least this long between words already placed; a shorter one is the same sound read differently.
    private static let minimumGapSeconds = 0.3

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
    /// Words the previous decode heard in this interval fill only the times this decode left empty.
    mutating func newWords(from decodedWords: [WordTiming], for plan: Plan) -> [WordTiming] {
        let owned = decodedWords.filter { word in
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
        // Time already spoken for: words committed earlier and the words this decode owns.
        let placed = recentWords.map { (word: $0.normalized, start: $0.start, end: $0.end) }
            + owned.map { (word: Self.normalize($0.word), start: plan.bufferOffset + $0.startTime, end: plan.bufferOffset + $0.endTime) }
        let recovered = heldTail.filter { held in
            let normalized = Self.normalize(held.word)
            guard plan.contains(start: held.startTime - plan.bufferOffset, end: held.endTime - plan.bufferOffset),
                  !placed.contains(where: { other in
                      max(other.start, held.startTime) < min(other.end, held.endTime)
                          || (other.word == normalized && abs(other.start - held.startTime) < Self.movedWordSeconds)
                  }) else { return false }
            let before = placed.filter { $0.end <= held.startTime }.map(\.end).max() ?? -.infinity
            let after = placed.filter { $0.start >= held.endTime }.map(\.start).min() ?? .infinity
            return after - before >= Self.minimumGapSeconds
        }.map { WordTiming(word: $0.word, startTime: $0.startTime - plan.bufferOffset, endTime: $0.endTime - plan.bufferOffset) }
        heldTail = decodedWords.filter { plan.bufferOffset + ($0.startTime + $0.endTime) / 2 >= plan.commitEnd }
            .map { WordTiming(word: $0.word, startTime: plan.bufferOffset + $0.startTime, endTime: plan.bufferOffset + $0.endTime) }
        guard !recovered.isEmpty else { return owned }
        // Words can share a start time; ties keep the decoder's order.
        return (owned + recovered).enumerated()
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
            .map(\.element)
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
        heldTail = []
    }

    private mutating func reset(sessionID: String, offset: Double) {
        samples.removeAll(keepingCapacity: true)
        self.sessionID = sessionID
        bufferOffset = offset
        expectedOffset = offset
        committedThrough = offset
        recentWords.removeAll(keepingCapacity: true)
        heldTail = []
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }
}
