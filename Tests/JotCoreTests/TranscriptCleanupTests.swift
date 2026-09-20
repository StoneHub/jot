import XCTest
@testable import JotCore

final class TranscriptCleanupTests: XCTestCase {
    func testLiveParagraphReplacesRawTextWithoutAddingRowsOrChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let start = Date()
        let first = Transcript(id: "first", sessionID: "live", startedAt: start, startSeconds: 0, endSeconds: 1,
                               text: "um hello", speakerID: "speaker-1", mode: "ambient")
        let second = Transcript(id: "second", sessionID: "live", startedAt: start, startSeconds: 1.1, endSeconds: 2,
                                text: "there", speakerID: "speaker-1", mode: "ambient")
        try store.append(first)
        try store.append(second)
        func paragraphs() throws -> [Transcript] {
            TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(try store.session(id: "live")))
        }
        let raw = try paragraphs()
        XCTAssertEqual(raw.map(\.text), ["um hello there"])
        let count = try store.sessions().first?.transcriptCount

        try store.setReadableText("Hello", for: first)
        let cleaned = try paragraphs()
        XCTAssertEqual(cleaned.map(\.text), ["Hello there"])
        XCTAssertEqual(cleaned.map(\.id), raw.map(\.id))
        XCTAssertEqual(cleaned.first?.startSeconds, raw.first?.startSeconds)
        XCTAssertEqual(cleaned.first?.endSeconds, raw.first?.endSeconds)
        XCTAssertEqual(try store.sessions().first?.transcriptCount, count)
    }

    @MainActor func testDictationCanInterruptAmbientCleanupImmediately() async {
        let cleanup = TranscriptCleanup()
        let started = expectation(description: "Model started")
        let work = Task {
            await cleanup.clean(["original"], generator: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
                return ["late"]
            })
        }
        await fulfillment(of: [started], timeout: 1)
        let began = ContinuousClock.now
        cleanup.cancel()
        let result = await work.value
        XCTAssertEqual(result, ["original"])
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(200))
    }

    func testRejectsObservedBudgetHallucinationAndLostQualification() {
        XCTAssertFalse(CleanupValidation.accepts("The budget is fifteen thousand dollars, not five thousand.", source: "The budget is fifteen, fifteen hundred dollars, not five thousand."))
        XCTAssertFalse(CleanupValidation.accepts("Ship Friday.", source: "Do not ship Friday."))
        XCTAssertFalse(CleanupValidation.accepts("I can test tomorrow.", source: "I can probably test tomorrow."))
        XCTAssertFalse(CleanupValidation.accepts("Budget: 15000.", source: "Budget: 1500."))
        XCTAssertTrue(CleanupValidation.accepts("I can probably test tomorrow.", source: "Um I can, I can probably test tomorrow."))
    }

    @MainActor func testPreservesTurnCountAndRejectsOnlyUnsafeEdits() async {
        let cleanup = TranscriptCleanup()
        let source = ["Um hello there.", "Do not ship."]
        let edited = await cleanup.clean(source, generator: { _ in ["Hello there.", "Ship."] })
        XCTAssertEqual(edited, ["Hello there.", "Do not ship."])
        let wrongCount = await cleanup.clean(source, generator: { _ in ["Merged speakers."] })
        XCTAssertEqual(wrongCount, source)
    }

    @MainActor func testDeadlineReturnsWithoutWaitingForUncooperativeGenerator() async {
        let cleanup = TranscriptCleanup()
        let began = ContinuousClock.now
        let result = await cleanup.clean(["original"], timeout: .milliseconds(20), generator: { _ in
            // Simulates a provider that does not stop immediately after task cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
            return ["late result"]
        })
        XCTAssertEqual(result, ["original"])
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(200))
        let bypass = await cleanup.clean(["next"], generator: { _ in XCTFail("No queued model calls while busy"); return ["wrong"] })
        XCTAssertEqual(bypass, ["next"])
        try? await Task.sleep(for: .milliseconds(350))
        let recovered = await cleanup.clean(["um recovered"], generator: { _ in ["recovered"] })
        XCTAssertEqual(recovered, ["recovered"])
    }

    @MainActor func testOversizedInputBypassesProvider() async {
        let source = [String(repeating: "a", count: 2401)]
        let result = await TranscriptCleanup().clean(source, generator: { _ in XCTFail("Input must be bounded"); return [] })
        XCTAssertEqual(result, source)
    }

    func testReadableTextSurvivesReopenAndCannotResurrectDeletedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Transcript(id: "source", sessionID: "session", startedAt: Date(), startSeconds: 0, endSeconds: 1, text: "um hello", mode: "ambient")
        do {
            let store = try TranscriptStore(directory: directory)
            try store.append(source)
            try store.setReadableText("Hello.", for: source)
        }
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.read(id: source.id)?.text, "Hello.")
        XCTAssertEqual(try store.search("Hello.").count, 1)
        XCTAssertEqual(try store.session(id: "session").first?.text, "Hello.")
        try store.deleteTranscripts(ids: [source.id])
        try store.setReadableText("late output", for: source)
        XCTAssertNil(try store.read(id: source.id))
        try store.append(source)
        XCTAssertEqual(try store.read(id: source.id)?.text, "um hello", "Derived text must cascade on deletion")
    }
}
