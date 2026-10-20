import XCTest
@testable import JotCore

final class RemoteModelProviderTests: XCTestCase {
    private let request = ModelRequest(instructions: "Edit.", prompt: #"["um hi"]"#, maximumResponseTokens: 500)

    func testEndpointsGainTheFormatPathAndRefusePlainHTTPOffThisMac() throws {
        let ollama = try XCTUnwrap(RemoteModelConfiguration(format: .openAICompatible, endpoint: "http://localhost:11434/v1/", model: " qwen3:4b "))
        XCTAssertEqual(ollama.requestURL.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(ollama.model, "qwen3:4b")
        XCTAssertTrue(ollama.isOnDevice)
        let full = try XCTUnwrap(RemoteModelConfiguration(format: .openAICompatible, endpoint: "http://127.0.0.1:1234/v1/chat/completions", model: "m"))
        XCTAssertEqual(full.requestURL.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        let anthropic = try XCTUnwrap(RemoteModelConfiguration(format: .anthropic, endpoint: "https://api.anthropic.com/v1", model: "m"))
        XCTAssertEqual(anthropic.requestURL.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertFalse(anthropic.isOnDevice)
        XCTAssertNil(RemoteModelConfiguration(format: .openAICompatible, endpoint: "http://192.168.1.5:11434/v1", model: "m"))
        XCTAssertNil(RemoteModelConfiguration(format: .openAICompatible, endpoint: "https://user:pass@example.com/v1", model: "m"))
        XCTAssertNil(RemoteModelConfiguration(format: .openAICompatible, endpoint: "localhost:11434", model: "m"))
        XCTAssertNil(RemoteModelConfiguration(format: .openAICompatible, endpoint: "https://example.com/v1", model: "  "))
    }

    func testOpenAICompatibleRequestCarriesTheKeyAndBoundsOnly() throws {
        let configuration = try XCTUnwrap(RemoteModelConfiguration(format: .openAICompatible, endpoint: "http://localhost:11434/v1", model: "qwen3:4b"))
        let urlRequest = try RemoteModelProvider.urlRequest(for: request, configuration: configuration, key: " sk-test ")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(body["max_tokens"] as? Int, 500)
        XCTAssertEqual(body["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Edit."], ["role": "user", "content": #"["um hi"]"#]])
        let keyless = try RemoteModelProvider.urlRequest(for: request, configuration: configuration, key: nil)
        XCTAssertNil(keyless.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAIsOwnAPIGetsCompletionTokensWithoutTemperature() throws {
        let configuration = try XCTUnwrap(RemoteModelConfiguration(format: .openAICompatible, endpoint: "https://api.openai.com/v1", model: "m"))
        let urlRequest = try RemoteModelProvider.urlRequest(for: request, configuration: configuration, key: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 500)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicRequestUsesItsHeadersAndSystemField() throws {
        let configuration = try XCTUnwrap(RemoteModelConfiguration(format: .anthropic, endpoint: "https://api.anthropic.com/v1", model: "m"))
        let urlRequest = try RemoteModelProvider.urlRequest(for: request, configuration: configuration, key: "k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "Edit.")
        XCTAssertEqual(body["max_tokens"] as? Int, 500)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 1)
    }

    func testRepliesAreReadPerFormatWithoutReasoning() throws {
        let openAI = Data(#"{"choices":[{"message":{"role":"assistant","content":"<think>hmm</think>\n Hi."}}]}"#.utf8)
        XCTAssertEqual(try RemoteModelProvider.text(from: openAI, format: .openAICompatible), "Hi.")
        let anthropic = Data(#"{"content":[{"type":"text","text":"Hi"},{"type":"text","text":" there."}]}"#.utf8)
        XCTAssertEqual(try RemoteModelProvider.text(from: anthropic, format: .anthropic), "Hi there.")
        XCTAssertThrowsError(try RemoteModelProvider.text(from: Data("{}".utf8), format: .openAICompatible))
    }

    func testListRepliesAreReadLeniently() throws {
        XCTAssertEqual(try RemoteModelProvider.texts(from: #"{"texts": ["Hi."]}"#), ["Hi."])
        XCTAssertEqual(try RemoteModelProvider.texts(from: "```json\n{\"texts\": [\"A.\", \"B.\"]}\n```"), ["A.", "B."])
        XCTAssertEqual(try RemoteModelProvider.texts(from: #"Here you go: ["A."]"#), ["A."])
        XCTAssertThrowsError(try RemoteModelProvider.texts(from: "Sorry, I can't."))
    }

    func testStatusErrorsCarryNoResponseText() async throws {
        let configuration = RemoteModelConfiguration(format: .openAICompatible, endpoint: "http://localhost:1/v1", model: "m")
        func provider(status: Int) -> RemoteModelProvider {
            RemoteModelProvider(configuration: configuration, key: { nil }, send: { request in
                (Data("echo of the prompt".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)! as URLResponse)
            })
        }
        do { _ = try await provider(status: 401).generate(request); XCTFail("Expected unauthorized") }
        catch let error as ModelUnavailable { XCTAssertEqual(error.reason, "unauthorized") }
        do { _ = try await provider(status: 500).generate(request); XCTFail("Expected a status failure") }
        catch let error as RemoteModelProvider.Failure { XCTAssertEqual(error, .status(500)) }
    }

    func testUnconfiguredProviderIsUnavailable() {
        let provider = RemoteModelProvider(configuration: nil, key: { nil })
        XCTAssertEqual(provider.availability, .notConfigured)
        XCTAssertFalse(provider.isOnDevice)
        XCTAssertNotNil(CleanupAvailability.notConfigured.suggestionBlocker)
    }
}
