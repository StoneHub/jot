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

        try store.setReadablePhrase(["Hello"], for: [first])
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

    @MainActor func testDictationInterruptionKeepsUncooperativeGeneratorBusy() async {
        let cleanup = TranscriptCleanup()
        let started = expectation(description: "Model started")
        let finished = expectation(description: "Model finished")
        let gate = CleanupGeneratorGate()
        let source = ["  um original\n", "Do not ship Friday."]
        let work = Task {
            await cleanup.clean(source, generator: { _ in
                await gate.wait(started: started)
                finished.fulfill()
                return ["Original.", "Do not ship Friday."]
            })
        }
        await fulfillment(of: [started], timeout: 1)
        let began = ContinuousClock.now
        cleanup.cancel()
        let result = await work.value
        XCTAssertEqual(result, source, "Interruption must preserve the exact raw entries")
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(200))

        let bypass = await cleanup.clean(["next"], generator: { _ in
            XCTFail("Dictation cancellation must not allow overlapping model calls")
            return ["wrong"]
        })
        XCTAssertEqual(bypass, ["next"])
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)
    }

    @MainActor func testGeneratorFailurePreservesExactRawTextAndAllowsNextRequest() async {
        struct ModelFailure: Error {}
        let cleanup = TranscriptCleanup()
        let source = ["  um café\n", "Do not ship Friday."]
        let result = await cleanup.clean(source, generator: { received in
            XCTAssertEqual(received, source)
            throw ModelFailure()
        })
        XCTAssertEqual(result, source)

        let recovered = await cleanup.clean(["um recovered"], generator: { _ in ["Recovered."] })
        XCTAssertEqual(recovered, ["Recovered."])
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

    @MainActor func testInputLimitCountsCombinedUTF8BytesAndIncludesBoundary() async {
        let cleanup = TranscriptCleanup()
        let source = [String(repeating: "é", count: 600), String(repeating: "é", count: 600)]
        let called = expectation(description: "Exactly 2400 bytes reaches the model")
        let accepted = await cleanup.clean(source, generator: { received in
            called.fulfill()
            XCTAssertEqual(received, source)
            return received
        })
        await fulfillment(of: [called], timeout: 1)
        XCTAssertEqual(accepted, source)

        let oversized = source + ["a"]
        let bypass = await cleanup.clean(oversized, generator: { _ in
            XCTFail("The byte budget applies across all entries, including multibyte text")
            return []
        })
        XCTAssertEqual(bypass, oversized)
    }

    func testReadableTextSurvivesReopenAndCannotResurrectDeletedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Transcript(id: "source", sessionID: "session", startedAt: Date(), startSeconds: 0, endSeconds: 1, text: "um hello", mode: "ambient")
        do {
            let store = try TranscriptStore(directory: directory)
            try store.append(source)
            try store.setReadablePhrase(["Hello."], for: [source])
        }
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.read(id: source.id)?.text, "Hello.")
        XCTAssertEqual(try store.search("Hello.").count, 1)
        XCTAssertEqual(try store.session(id: "session").first?.text, "Hello.")
        try store.setReadablePhrase(["Hello again."], for: [source])
        XCTAssertEqual(try store.read(id: source.id)?.text, "Hello again.",
                       "The original source must still match after storing and reopening derived text")
        try store.deleteTranscripts(ids: [source.id])
        try store.setReadablePhrase(["late output"], for: [source])
        XCTAssertNil(try store.read(id: source.id))
        try store.append(source)
        XCTAssertEqual(try store.read(id: source.id)?.text, "um hello", "Derived text must cascade on deletion")
    }
}

/// Keeps model work alive until explicitly released, even when its task is cancelled.
private actor CleanupGeneratorGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
