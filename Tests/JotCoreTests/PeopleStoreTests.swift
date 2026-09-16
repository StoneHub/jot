import XCTest
@testable import JotCore

final class PeopleStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-people-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func length(_ vector: [Float]) -> Float { vector.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    func testPeopleAreAddedListedRenamedAndDeleted() throws {
        let store = try PeopleStore(directory: directory)
        let added = try store.add(name: "  Monroe ", embedding: [3, 4])
        try store.add(name: "alice", embedding: [0, 1])
        XCTAssertEqual(try store.list().map(\.name), ["alice", "Monroe"])
        let monroe = try XCTUnwrap(try store.list().last)
        XCTAssertEqual(monroe.id, added.id); XCTAssertEqual(monroe.name, "Monroe"); XCTAssertEqual(monroe.sampleCount, 1)
        XCTAssertEqual(monroe.embedding, [0.6, 0.8]); XCTAssertEqual(monroe.createdAt.timeIntervalSince1970, added.createdAt.timeIntervalSince1970, accuracy: 1e-3)
        try store.rename(id: added.id, name: "Monroe S")
        XCTAssertEqual(try store.list().last?.name, "Monroe S")
        try store.delete(id: added.id)
        XCTAssertEqual(try store.list().map(\.name), ["alice"])
        XCTAssertThrowsError(try store.delete(id: added.id))
        XCTAssertThrowsError(try store.rename(id: "missing", name: "x"))
        XCTAssertThrowsError(try store.add(name: " ", embedding: [1]))
        XCTAssertThrowsError(try store.add(name: "Zero", embedding: [0, 0]))
        // The same file the transcripts use; a second connection sees the rows.
        XCTAssertEqual(try PeopleStore(directory: directory).list().map(\.name), ["alice"])
    }

    func testUpdatingAnEmbeddingAveragesByWeightAndKeepsUnitLength() throws {
        let store = try PeopleStore(directory: directory)
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        let person = try store.add(name: "Monroe", embedding: [1, 0], now: Date(timeIntervalSince1970: 1_000_000_000))
        try store.updateEmbedding(id: person.id, with: [0, 2], now: later)
        var stored = try XCTUnwrap(try store.list().first)
        XCTAssertEqual(stored.sampleCount, 2); XCTAssertEqual(stored.updatedAt, later)
        XCTAssertEqual(stored.embedding.map { ($0 * 1000).rounded() / 1000 }, [0.707, 0.707])
        XCTAssertEqual(length(stored.embedding), 1, accuracy: 1e-6)
        // Two samples already stored: the third counts for a third of the mean before it is scaled back to unit length.
        try store.updateEmbedding(id: person.id, with: [0, 1])
        stored = try XCTUnwrap(try store.list().first)
        XCTAssertEqual(stored.sampleCount, 3)
        XCTAssertEqual(stored.embedding.map { ($0 * 1000).rounded() / 1000 }, [0.505, 0.863])
        XCTAssertEqual(length(stored.embedding), 1, accuracy: 1e-6)
        XCTAssertThrowsError(try store.updateEmbedding(id: person.id, with: [1, 2, 3]))
        XCTAssertThrowsError(try store.updateEmbedding(id: "missing", with: [1, 0]))
    }

    func testMatcherPicksTheNearestPersonUnderTheThresholdAndNobodyAboveIt() throws {
        let now = Date()
        let near = Person(id: "near", name: "Near", embedding: [1, 0], sampleCount: 1, createdAt: now, updatedAt: now)
        let nearer = Person(id: "nearer", name: "Nearer", embedding: [0.6, 0.8], sampleCount: 1, createdAt: now, updatedAt: now)
        let far = Person(id: "far", name: "Far", embedding: [-1, 0], sampleCount: 1, createdAt: now, updatedAt: now)
        let odd = Person(id: "odd", name: "Odd", embedding: [1, 0, 0], sampleCount: 1, createdAt: now, updatedAt: now)
        let match = try XCTUnwrap(PeopleMatcher.match(embedding: [0.8, 0.6], people: [far, near, nearer, odd]))
        XCTAssertEqual(match.id, "nearer"); XCTAssertEqual(match.distance, 0.04, accuracy: 1e-6)
        XCTAssertNil(PeopleMatcher.match(embedding: [0.8, 0.6], people: [far, odd]))
        XCTAssertNil(PeopleMatcher.match(embedding: [0.8, 0.6], people: []))
        XCTAssertEqual(PeopleMatcher.match(embedding: [1, 0], people: [far], threshold: 2)?.id, "far")
        XCTAssertEqual(PeopleMatcher.threshold, 0.65)
        XCTAssertEqual(PeopleMatcher.distance([1, 0], [-1, 0]), 2); XCTAssertEqual(PeopleMatcher.distance([2, 0], [5, 0]), 0)
        XCTAssertNil(PeopleMatcher.distance([1, 0], [0, 0])); XCTAssertNil(PeopleMatcher.distance([], []))
    }

    func testAssignmentsPairEachSpeakerAndPersonOnceNearestFirst() {
        let now = Date()
        let monroe = Person(id: "m", name: "Monroe", embedding: [1, 0], sampleCount: 1, createdAt: now, updatedAt: now)
        let alice = Person(id: "a", name: "Alice", embedding: [0.6, 0.8], sampleCount: 1, createdAt: now, updatedAt: now)
        // speaker-1 is closest to Monroe but speaker-2 is even closer to him, so speaker-2 takes Monroe and speaker-1 falls to Alice; speaker-3 is near nobody.
        let speakers: [String: [Float]] = ["speaker-1": [0.8, 0.6], "speaker-2": [1, 0.1], "speaker-3": [0, -1]]
        let result = PeopleMatcher.assignments(speakers: speakers, people: [alice, monroe])
        XCTAssertEqual(result.map(\.speaker), ["speaker-2", "speaker-1"]); XCTAssertEqual(result.map(\.id), ["m", "a"])
        XCTAssertEqual(result[1].distance, 0.04, accuracy: 1e-6)
        XCTAssertTrue(PeopleMatcher.assignments(speakers: speakers, people: []).isEmpty)
    }
}
