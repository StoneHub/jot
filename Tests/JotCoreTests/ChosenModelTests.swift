import XCTest
@testable import JotCore

final class ChosenModelTests: XCTestCase {
    private struct FixedProvider: GenerationProvider {
        var availability: CleanupAvailability { .available }
        var isOnDevice: Bool { true }
        func generate(_ request: ModelRequest) async throws -> String { "apple" }
        func generateTexts(_ request: ModelRequest) async throws -> [String] { ["apple"] }
    }

    func testAppleIntelligenceStaysTheDefaultForEveryFeature() async throws {
        let settings = JotSettings(defaults: MemoryDefaults())
        for feature in [ChosenModel.Feature.cleanup, .suggestions, .notes] {
            let model = ChosenModel(feature, settings: settings, apple: FixedProvider(), key: { _ in XCTFail("No key is read for Apple"); return nil })
            XCTAssertFalse(model.usesCustomModel)
            XCTAssertTrue(model.isOnDevice)
            XCTAssertEqual(model.availability(orApple: .notEnabled), .notEnabled)
            let text = try await model.generate(ModelRequest(instructions: "", prompt: "", maximumResponseTokens: 1))
            XCTAssertEqual(text, "apple")
        }
    }

    func testEachFeatureOptsInSeparately() throws {
        let settings = JotSettings(defaults: MemoryDefaults())
        settings.set(JotSettings.customModelForSuggestions, true)
        XCTAssertFalse(ChosenModel(.cleanup, settings: settings, apple: FixedProvider()).usesCustomModel)
        XCTAssertFalse(ChosenModel(.notes, settings: settings, apple: FixedProvider()).usesCustomModel)
        let suggestions = ChosenModel(.suggestions, settings: settings, apple: FixedProvider(), key: { _ in nil })
        XCTAssertTrue(suggestions.usesCustomModel)
        XCTAssertTrue(suggestions.current is RemoteModelProvider)
        XCTAssertTrue(suggestions.isOnDevice, "The default endpoint is Ollama on this Mac")
        XCTAssertEqual(suggestions.availability(orApple: .notEnabled), .available)

        try settings.set(JotSettings.customModelEndpoint, "https://api.example.com/v1")
        XCTAssertFalse(suggestions.isOnDevice)
        try settings.set(JotSettings.customModelEndpoint, "http://192.168.1.9:11434/v1")
        XCTAssertEqual(suggestions.availability, .notConfigured, "Plain HTTP off this Mac is refused")
        try settings.set(JotSettings.customModelFormat, "gemini")
        XCTAssertNil(settings.customModel)
    }
}
