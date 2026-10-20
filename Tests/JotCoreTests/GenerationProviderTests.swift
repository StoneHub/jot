import XCTest
@testable import JotCore

final class GenerationProviderTests: XCTestCase {
    /// Records the one request it receives and answers with `answer`.
    private final class RecordingProvider: GenerationProvider, @unchecked Sendable {
        let availability: CleanupAvailability
        let answer: [String]
        private let lock = NSLock()
        private var requests: [ModelRequest] = []
        init(availability: CleanupAvailability = .available, answer: [String]) {
            self.availability = availability; self.answer = answer
        }
        var isOnDevice: Bool { false }
        var received: [ModelRequest] { lock.withLock { requests } }
        func generate(_ request: ModelRequest) async throws -> String { answer.joined() }
        func generateTexts(_ request: ModelRequest) async throws -> [String] {
            lock.withLock { requests.append(request) }
            return answer
        }
    }

    @MainActor func testCleanupSendsInstructionsJSONInputAndTokenLimitToTheProvider() async throws {
        let settings = JotSettings(defaults: MemoryDefaults())
        settings.set(JotSettings.cleanupMaximumTokens, 800)
        let provider = RecordingProvider(answer: ["Ship 15 items."])
        let result = await TranscriptCleanup(settings: settings, provider: provider).cleanWithOutcome(["um ship 15 items"])
        XCTAssertEqual(result.outcome, .changed)
        XCTAssertEqual(result.texts, ["Ship 15 items."])
        let request = try XCTUnwrap(provider.received.first)
        XCTAssertEqual(request.instructions, settings.text(JotSettings.cleanupInstructions))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(request.prompt.utf8)), ["um ship 15 items"])
        XCTAssertEqual(request.maximumResponseTokens, 800)
    }

    @MainActor func testUnavailableProviderSeesNoInput() async {
        let provider = RecordingProvider(availability: .modelNotReady, answer: ["unexpected"])
        let result = await TranscriptCleanup(provider: provider).cleanWithOutcome(["keep this"])
        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(result.texts, ["keep this"])
        XCTAssertTrue(provider.received.isEmpty)
    }

    @MainActor func testProviderOutputStillPassesCleanupValidation() async {
        let provider = RecordingProvider(answer: ["Do ship 16 items."])
        let result = await TranscriptCleanup(provider: provider).cleanWithOutcome(["do not ship 15 items"])
        XCTAssertEqual(result.outcome, .rejectedEdits)
        XCTAssertEqual(result.texts, ["do not ship 15 items"])
    }

    func testAppleIntelligenceIsTheOnDeviceDefault() {
        XCTAssertTrue(AppleIntelligenceProvider().isOnDevice)
    }
}
