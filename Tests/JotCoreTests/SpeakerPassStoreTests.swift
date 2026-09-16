import XCTest
@testable import JotCore

final class SpeakerPassStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-speakers-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func result(_ segments: [(speaker: String, start: Double, end: Double)], speakers: [String: [Float]]) -> SpeakerPassResult {
        SpeakerPassResult(segments: segments, speakers: speakers, durationSeconds: 60, processingSeconds: 1)
    }

    func testRowsRoundTripThroughTheSharedDatabaseAndAReplaceClearsTheEarlierPass() throws {
        let transcripts = try TranscriptStore(directory: directory)
        try transcripts.append(Transcript(id: "t", sessionID: "s", startedAt: Date(), startSeconds: 0, endSeconds: 1, text: "hi", mode: "ambient"))
        let store = try SpeakerPassStore(directory: directory)
        let first = result([("S1", 0, 2.5), ("S2", 2.5, 4), ("S1", 4, 5)], speakers: ["S1": [0.5, -1.25, 3], "S2": [1e-3, 2]])
        try store.replace(sessionID: "s", result: first)
        XCTAssertEqual(try store.speakers(sessionID: "s"), [
            .init(speakerID: "S1", embedding: [0.5, -1.25, 3], durationSeconds: 3.5),
            .init(speakerID: "S2", embedding: [1e-3, 2], durationSeconds: 1.5)
        ])
        XCTAssertEqual(try store.segments(sessionID: "s"), [.init(speakerID: "S1", start: 0, end: 2.5), .init(speakerID: "S2", start: 2.5, end: 4), .init(speakerID: "S1", start: 4, end: 5)])
        XCTAssertEqual(try store.segments(sessionID: "other"), [])

        try store.replace(sessionID: "s", result: result([("S1", 1, 2)], speakers: ["S1": [1]]))
        XCTAssertEqual(try store.speakers(sessionID: "s").map(\.speakerID), ["S1"])
        XCTAssertEqual(try store.segments(sessionID: "s"), [.init(speakerID: "S1", start: 1, end: 2)])
        XCTAssertEqual(try transcripts.read(id: "t")?.text, "hi")
    }

    func testEmbeddingsAreStoredAsLittleEndianFloat32() {
        let blob = SpeakerPassStore.blob([1, -2])
        XCTAssertEqual([UInt8](blob), [0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0])
        XCTAssertEqual(SpeakerPassStore.floats(blob), [1, -2])
        XCTAssertEqual(SpeakerPassStore.floats(Data([1, 2, 3])), [])
    }

    func testInvalidTimesAndEmbeddingsAreRejectedWhole() throws {
        let store = try SpeakerPassStore(directory: directory)
        XCTAssertThrowsError(try store.replace(sessionID: "s", result: result([("S1", 3, 2)], speakers: ["S1": [1]])))
        XCTAssertThrowsError(try store.replace(sessionID: "s", result: result([("S1", 0, 1)], speakers: ["S1": []])))
        XCTAssertThrowsError(try store.replace(sessionID: "s", result: result([("S1", 0, 1)], speakers: ["S1": [.nan]])))
        XCTAssertThrowsError(try store.replace(sessionID: "", result: result([], speakers: [:])))
        XCTAssertEqual(try store.segments(sessionID: "s"), [])
    }
}
