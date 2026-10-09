import FluidAudio
import XCTest
@testable import JotEngine

final class RecognitionCommitWindowTests: XCTestCase {
    /// Recognition windows retain bounded context, flush tails, deduplicate seams, preserve repeats, and reset at boundaries.
    func testCommitWindowKeepsBoundedContextAndResetsAtBoundaries() {
        var window = RecognitionCommitWindow(contextSeconds: 2, sampleRate: 10)
        let first = window.plan(sessionID: "a", offset: 0,
            newSamples: Array(repeating: 1, count: 30), isFinal: false)
        XCTAssertTrue(first.samples.count == 30 && first.commitStart == 0 && first.commitEnd == 1)
        let firstWords = window.newWords(from: [
            WordTiming(word: "Echo", startTime: 0.8, endTime: 1.0)
        ], for: first)
        XCTAssertTrue(firstWords.count == 1)
        window.commit(first, words: firstWords)

        let second = window.plan(sessionID: "a", offset: 3,
            newSamples: Array(repeating: 2, count: 30), isFinal: false)
        let seamWords = window.newWords(from: [
            // Same acoustic word moved across the commit cursor on a re-decode.
            WordTiming(word: "echo", startTime: 0.85, endTime: 1.15),
            // A genuine adjacent repetition has a distinct, non-overlapping time.
            WordTiming(word: "echo", startTime: 1.16, endTime: 1.34)
        ], for: second)
        XCTAssertTrue(seamWords.count == 1 && seamWords[0].startTime == 1.16,
            "Commit seam duplicate handling removed genuine repeated speech")
        window.commit(second, words: seamWords)

        let third = window.plan(sessionID: "a", offset: 6,
            newSamples: Array(repeating: 3, count: 30), isFinal: false)
        XCTAssertTrue(third.samples.count == 70, "Recognition context exceeded or lost the seven-second bound")
        XCTAssertTrue(!third.contains(start: 5, end: 5), "Non-final commit intervals must be half-open")
        window.commit(third)

        let final = window.plan(sessionID: "a", offset: 9, newSamples: [], isFinal: true)
        XCTAssertTrue(final.samples.count == 40 && final.commitStart == 7 && final.commitEnd == 9,
            "An empty final job did not expose the retained two-second tail")
        window.commit(final)
        let afterFinal = window.plan(sessionID: "a", offset: 9,
            newSamples: Array(repeating: 4, count: 30), isFinal: false)
        XCTAssertTrue(afterFinal.samples.count == 30 && afterFinal.bufferOffset == 9,
            "Final commit did not reset recognition context")
        window.commit(afterFinal)

        let newSession = window.plan(sessionID: "b", offset: 12,
            newSamples: Array(repeating: 5, count: 30), isFinal: false)
        XCTAssertTrue(newSession.samples.count == 30 && newSession.bufferOffset == 12,
            "Session rotation retained prior recognition audio")
        window.commit(newSession)
        let discontinuity = window.plan(sessionID: "b", offset: 20,
            newSamples: Array(repeating: 6, count: 30), isFinal: false)
        XCTAssertTrue(discontinuity.samples.count == 30 && discontinuity.bufferOffset == 20,
            "A discontinuity retained prior recognition audio")

        // SpeechPipeline uses this same reset when a plan throws, bounding the
        // next recognition window instead of accumulating failed audio.
        window.reset()
        let afterError = window.plan(sessionID: "b", offset: 23,
            newSamples: Array(repeating: 7, count: 30), isFinal: false)
        XCTAssertTrue(afterError.samples.count == 30 && afterError.bufferOffset == 23,
            "An abandoned recognition plan retained failed audio")
    }

    /// #215: a decode can miss words at the start of the interval it owns that the previous decode heard in its uncommitted tail.
    /// Those words are committed where the owning decode missed them, without duplicates.
    func testCommitSeamFallbackKeepsTailWordsTheOwningDecodeMissed() {
        var window = RecognitionCommitWindow(contextSeconds: 2, sampleRate: 10)
        let first = window.plan(sessionID: "a", offset: 0, newSamples: Array(repeating: 1, count: 30), isFinal: false)
        let firstWords = window.newWords(from: [
            WordTiming(word: "alpha", startTime: 0.2, endTime: 0.5),
            WordTiming(word: "bravo", startTime: 1.2, endTime: 1.5),
            WordTiming(word: "charlie", startTime: 2.2, endTime: 2.6)
        ], for: first)
        XCTAssertTrue(firstWords.map(\.word) == ["alpha"], "Tail words were committed before their interval")
        window.commit(first, words: firstWords)

        // The owning decode returns nothing before its own tail.
        let second = window.plan(sessionID: "a", offset: 3, newSamples: Array(repeating: 2, count: 30), isFinal: false)
        let secondWords = window.newWords(from: [
            WordTiming(word: "delta", startTime: 4.3, endTime: 4.6),
            WordTiming(word: "kilo", startTime: 5.6, endTime: 5.8),
            WordTiming(word: "the", startTime: 6.34, endTime: 6.42)
        ], for: second)
        XCTAssertTrue(secondWords.map(\.word) == ["bravo", "charlie"]
            && secondWords.map(\.startTime) == [1.2, 2.2].map { $0 - second.bufferOffset },
            "Words the previous decode heard in its tail were dropped when the owning decode missed them: \(secondWords.map(\.word))")
        window.commit(second, words: secondWords)

        // Where the owning decode has a word at that time, or the same word moved a little, it wins: no duplicate of the held word.
        let third = window.plan(sessionID: "a", offset: 6, newSamples: Array(repeating: 3, count: 30), isFinal: false)
        let thirdWords = window.newWords(from: [
            WordTiming(word: "delta", startTime: 4.25 - third.bufferOffset, endTime: 4.6 - third.bufferOffset),
            WordTiming(word: "echo", startTime: 5.0 - third.bufferOffset, endTime: 5.3 - third.bufferOffset),
            WordTiming(word: "kilo", startTime: 5.9 - third.bufferOffset, endTime: 6.1 - third.bufferOffset),
            // The same sound read as another word, with no real gap around the held one.
            WordTiming(word: "carved", startTime: 6.1 - third.bufferOffset, endTime: 6.3 - third.bufferOffset),
            WordTiming(word: "a", startTime: 6.46 - third.bufferOffset, endTime: 6.54 - third.bufferOffset),
            WordTiming(word: "golf", startTime: 7.5 - third.bufferOffset, endTime: 7.8 - third.bufferOffset)
        ], for: third)
        XCTAssertTrue(thirdWords.map(\.word) == ["delta", "echo", "kilo", "carved", "a"] && abs(thirdWords[0].startTime + third.bufferOffset - 4.25) < 1e-9,
            "A held tail word duplicated or replaced the owning decode's word: \(thirdWords.map(\.word))")
        window.commit(third, words: thirdWords)

        // A final decode that misses the held tail still commits it, then nothing is held past the reset.
        let final = window.plan(sessionID: "a", offset: 9, newSamples: [], isFinal: true)
        let finalWords = window.newWords(from: [], for: final)
        XCTAssertTrue(finalWords.map(\.word) == ["golf"], "A final decode dropped the held tail: \(finalWords.map(\.word))")
        window.commit(final, words: finalWords)
        // A word that moves across the cursor between decodes: the previous decode held it just after, the owning decode heard it
        // just before, where it doesn't own it. It is committed once, after equal-time words that keep the decoder's order.
        var jitter = RecognitionCommitWindow(contextSeconds: 2, sampleRate: 10)
        let early = jitter.plan(sessionID: "j", offset: 0, newSamples: Array(repeating: 1, count: 30), isFinal: false)
        jitter.commit(early, words: jitter.newWords(from: [WordTiming(word: "bravo", startTime: 0.95, endTime: 1.25)], for: early))
        let owning = jitter.plan(sessionID: "j", offset: 3, newSamples: Array(repeating: 2, count: 30), isFinal: false)
        let owningWords = jitter.newWords(from: [
            WordTiming(word: "bravo", startTime: 0.8, endTime: 1.1),
            WordTiming(word: "of", startTime: 2.0, endTime: 2.1),
            WordTiming(word: "the", startTime: 2.0, endTime: 2.1),
            WordTiming(word: "zulu", startTime: 4.5, endTime: 4.8)
        ], for: owning)
        XCTAssertTrue(owningWords.map(\.word) == ["bravo", "of", "the"],
            "A word that moved across the cursor was lost, or equal-time words changed order: \(owningWords.map(\.word))")
        jitter.commit(owning, words: owningWords)
        // A new session starts its clock at zero; nothing held from the old one may fill it.
        let rotated = jitter.plan(sessionID: "k", offset: 0, newSamples: Array(repeating: 3, count: 90), isFinal: false)
        XCTAssertTrue(jitter.newWords(from: [], for: rotated).isEmpty, "A held word crossed into a new session")

        let afterFinal = window.plan(sessionID: "a", offset: 9, newSamples: Array(repeating: 4, count: 30), isFinal: true)
        XCTAssertTrue(window.newWords(from: [], for: afterFinal).isEmpty, "A held word outlived the final reset")
    }

    /// A boundary right after a final job closes a chunk with no context before it. Under the recognizer's 0.3-second minimum,
    /// it reaches ASR with trailing silence; only words in the real audio are committed, and the plan keeps the real length.
    func testShortFinalRecognitionIsPaddedAndCommitsOnlyRealWords() {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioClock.sampleRate)
        var window = RecognitionCommitWindow()
        let short = [Float](repeating: 0.5, count: AudioClock.samples(seconds: 0.2))
        let plan = window.plan(sessionID: "a", offset: 10, newSamples: short, isFinal: true)
        XCTAssertTrue(plan.samples == short && abs(plan.commitEnd - 10.2) < 1e-9, "A short final plan did not cover only its own audio")
        let audio = SpeechPipeline.recognitionAudio(plan.samples)
        XCTAssertTrue(audio.count == minimum && Array(audio.prefix(short.count)) == short && audio.dropFirst(short.count).allSatisfy { $0 == 0 },
            "Short recognition audio was not padded with trailing silence to the recognizer's minimum")
        let words = window.newWords(from: [
            WordTiming(word: "Yes", startTime: 0.04, endTime: 0.18),
            WordTiming(word: "uh", startTime: 0.22, endTime: 0.28)
        ], for: plan)
        XCTAssertTrue(words.map(\.word) == ["Yes"] && words[0].startTime == 0.04, "A word decoded in the padding was committed, or a real word moved")
        let long = [Float](repeating: 0.5, count: minimum)
        XCTAssertTrue(SpeechPipeline.recognitionAudio(long) == long, "Audio at the recognizer's minimum was changed")
    }
}
