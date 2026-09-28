import XCTest
@testable import JotCore

final class UserVoiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-you-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testLearningAveragesTrustsAfterEnoughHeldSpeechAndMatchesOnlyThatVoice() throws {
        let store = UserVoiceStore(directory: directory)
        XCTAssertNil(store.load())
        let first = try store.learn([1, 0], heldSeconds: 8, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertFalse(first.trusted)
        XCTAssertFalse(first.matches([1, 0]), "Under the minimum held speech, no voice is the user's yet")
        let later = Date(timeIntervalSince1970: 2_000)
        let second = try store.learn([0, 2], heldSeconds: 15, now: later)
        XCTAssertEqual(second.embedding.map { ($0 * 1000).rounded() / 1000 }, [0.707, 0.707], "Weighted by samples and kept unit length, like People")
        XCTAssertEqual(second.sampleCount, 2)
        XCTAssertEqual(second.heldSeconds, 23)
        XCTAssertEqual(second.updatedAt, later)
        XCTAssertTrue(second.trusted)
        XCTAssertEqual(store.load(), second)
        XCTAssertTrue(second.matches([1, 1]), "The same direction is the user")
        XCTAssertTrue(second.matches([1, 0.5]), "Within the People threshold")
        XCTAssertFalse(second.matches([-1, 1]), "A second person's voice, at right angles, is not")
        XCTAssertFalse(second.matches([1, 1, 0]), "Another embedding size never matches")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.learn([0, 0], heldSeconds: 5))
        XCTAssertThrowsError(try store.learn([1, 0], heldSeconds: 0))
        XCTAssertEqual(store.load(), second, "A refused sample changes nothing")
        try store.forget()
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.forget(), "Forgetting twice is fine")
    }

    func testAnotherEmbeddingSizeStartsOverAndAnotherFileVersionIsIgnored() throws {
        let store = UserVoiceStore(directory: directory)
        try store.learn([1, 0], heldSeconds: 30)
        let restarted = try store.learn([0, 0, 3], heldSeconds: 5)
        XCTAssertEqual(restarted.embedding, [0, 0, 1])
        XCTAssertEqual(restarted.sampleCount, 1)
        XCTAssertEqual(restarted.heldSeconds, 5, "A new speaker model's embeddings start a new average")
        try Data(#"{"version": 99, "embedding": [1, 0], "sampleCount": 3, "heldSeconds": 60, "updatedAt": 0}"#.utf8).write(to: store.url)
        XCTAssertNil(store.load(), "A file this build does not understand is ignored, and the voice is learned again")
        XCTAssertEqual(try store.learn([1, 0], heldSeconds: 4).sampleCount, 1)
    }
}
