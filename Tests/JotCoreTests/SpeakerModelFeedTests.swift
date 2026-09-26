import XCTest
@testable import JotCore

final class SpeakerModelFeedTests: XCTestCase {
    /// 100 samples a second and 8-sample frames keep the arithmetic readable; the hold is 50 samples.
    private func feed() -> SpeakerModelFeed { SpeakerModelFeed(sampleRate: 100, frameSeconds: 0.08, holdSeconds: 0.5) }

    /// Session audio whose every sample is its own index on the session clock.
    private func clock(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    func testQuietAudioIsHeldBackFromTheModel() {
        var feed = feed()
        feed.holdQuiet(clock(0..<30))
        XCTAssertEqual(feed.heldSampleCount, 30, "Quiet audio must wait rather than reach the speaker model")
        XCTAssertEqual(feed.skippedSamples, 0)
    }

    func testSpeechAfterAShortQuietGivesTheModelEveryHeldSampleInOrder() {
        var feed = feed()
        XCTAssertEqual(feed.releaseForSpeech(clock(0..<13)), clock(0..<13))
        feed.holdQuiet(clock(13..<40))
        feed.holdQuiet(clock(40..<51))
        XCTAssertEqual(feed.releaseForSpeech(clock(51..<70)), clock(13..<70), "A quiet shorter than the hold must reach the model unchanged")
        XCTAssertEqual(feed.heldSampleCount, 0)
        XCTAssertEqual(feed.skippedSamples, 0)
        for frame in 0..<9 { XCTAssertEqual(feed.sessionFrame(forModelFrame: frame), frame) }
    }

    func testLongQuietKeepsOnlyTheHoldAndSkipsWholeFrames() {
        var feed = feed()
        _ = feed.releaseForSpeech(clock(0..<20))
        for lower in stride(from: 20, to: 300, by: 7) { feed.holdQuiet(clock(lower..<min(lower + 7, 300))) }
        XCTAssertLessThanOrEqual(feed.heldSampleCount, feed.holdSamples, "Held quiet audio must stay bounded")
        XCTAssertGreaterThan(feed.heldSampleCount, feed.holdSamples - feed.frameSamples, "Speech must still find the hold's worth of audio before it")
        XCTAssertEqual(feed.skippedSamples % feed.frameSamples, 0, "Skips must keep the model's frames on the session's frame grid")
        XCTAssertEqual(feed.skippedSamples + feed.heldSampleCount, 280)
        let held = feed.heldSampleCount
        XCTAssertEqual(feed.releaseForSpeech(clock(300..<320)), clock((300 - held)..<320), "Speech must bring the most recent quiet with it")
    }

    /// Whatever mix of speech and quiet arrives, each frame the model reports maps to the session frame its first sample came from.
    func testEveryModelFrameMapsToItsSessionFrame() {
        var feed = feed()
        var modelStream: [Float] = []
        var next = 0
        // Job lengths and speech decisions vary so skips land on and off frame boundaries.
        let jobs: [(length: Int, speech: Bool)] = [(13, true), (70, false), (9, false), (31, true), (5, false),
            (120, false), (3, true), (64, false), (17, false), (22, true), (8, true), (200, false), (11, true)]
        for job in jobs {
            let samples = clock(next..<(next + job.length))
            next += job.length
            if job.speech { modelStream += feed.releaseForSpeech(samples) } else { feed.holdQuiet(samples) }
        }
        XCTAssertGreaterThan(feed.skippedSamples, 0)
        for frame in 0..<(modelStream.count / feed.frameSamples) {
            let firstSample = Int(modelStream[frame * feed.frameSamples])
            XCTAssertEqual(firstSample % feed.frameSamples, frame * feed.frameSamples % feed.frameSamples)
            XCTAssertEqual(feed.sessionFrame(forModelFrame: frame), firstSample / feed.frameSamples,
                "Model frame \(frame) starts at session sample \(firstSample)")
        }
    }

    func testResetStartsTheModelOver() {
        var feed = feed()
        _ = feed.releaseForSpeech(clock(0..<16))
        feed.holdQuiet(clock(16..<200))
        feed.reset()
        XCTAssertEqual(feed.heldSampleCount, 0)
        XCTAssertEqual(feed.skippedSamples, 0)
        XCTAssertEqual(feed.releaseForSpeech(clock(0..<8)), clock(0..<8))
        XCTAssertEqual(feed.sessionFrame(forModelFrame: 0), 0)
    }
}
