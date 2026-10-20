import Foundation

/// A model reached over HTTP. Each call is one stateless request: Jot's instructions as the system prompt and the
/// prompt as the single user message. Errors carry only a status code, never response text, which can echo the prompt.
public struct RemoteModelProvider: GenerationProvider {
    public enum Failure: Error, Equatable {
        /// The server answered with this HTTP status.
        case status(Int)
        /// The response had no text where the format puts it.
        case malformedResponse
    }

    public let configuration: RemoteModelConfiguration?
    private let key: @Sendable () -> String?
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `key` is read for each request, so a key saved or removed in Settings applies to the next call.
    public init(configuration: RemoteModelConfiguration?, key: @escaping @Sendable () -> String?,
                send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.configuration = configuration
        self.key = key
        self.send = send
    }

    public var isOnDevice: Bool { configuration?.isOnDevice ?? false }

    public var availability: CleanupAvailability { configuration == nil ? .notConfigured : .available }

    public func generate(_ request: ModelRequest) async throws -> String {
        guard let configuration else { throw ModelUnavailable(reason: CleanupAvailability.notConfigured.rawValue) }
        let (data, response) = try await send(try Self.urlRequest(for: request, configuration: configuration, key: key()))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ModelUnavailable(reason: "unauthorized") }
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return try Self.text(from: data, format: configuration.format)
    }

    /// Servers differ in structured-output support, so the list is asked for in the instructions and read leniently.
    public func generateTexts(_ request: ModelRequest) async throws -> [String] {
        let asking = ModelRequest(instructions: request.instructions + " " + Self.listInstruction,
                                  prompt: request.prompt, maximumResponseTokens: request.maximumResponseTokens)
        return try Self.texts(from: try await generate(asking))
    }

    static let listInstruction = #"Reply with only a JSON object of the form {"texts": ["…"]}, one string per input entry, and nothing else."#

    static func urlRequest(for request: ModelRequest, configuration: RemoteModelConfiguration, key: String?) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.requestURL, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        switch configuration.format {
        case .openAICompatible:
            if let key, !key.isEmpty { urlRequest.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            var fields: [String: Any] = ["model": configuration.model, "stream": false,
                "messages": [["role": "system", "content": request.instructions], ["role": "user", "content": request.prompt]]]
            // OpenAI's own API refuses `max_tokens` and a fixed temperature for its reasoning models; other servers expect them.
            if configuration.requestURL.host?.lowercased() == "api.openai.com" {
                fields["max_completion_tokens"] = request.maximumResponseTokens
            } else {
                fields["max_tokens"] = request.maximumResponseTokens
                fields["temperature"] = 0
            }
            body = fields
        case .anthropic:
            if let key, !key.isEmpty { urlRequest.setValue(key, forHTTPHeaderField: "x-api-key") }
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": configuration.model, "max_tokens": request.maximumResponseTokens, "system": request.instructions,
                    "messages": [["role": "user", "content": request.prompt]]]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func text(from data: Data, format: RemoteModelConfiguration.Format) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text: String?
        switch format {
        case .openAICompatible:
            let message = (object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        case .anthropic:
            let blocks = object?["content"] as? [[String: Any]]
            text = blocks?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        guard let text else { throw Failure.malformedResponse }
        return withoutReasoning(text)
    }

    /// Local reasoning models, such as Qwen3 in Ollama, can open their answer with a `<think>` block.
    static func withoutReasoning(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The `texts` list from a reply, inside a Markdown fence or not; a bare array is accepted too.
    static func texts(from reply: String) throws -> [String] {
        struct Wrapped: Decodable { let texts: [String] }
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
        }
        let decoder = JSONDecoder()
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let wrapped = try? decoder.decode(Wrapped.self, from: Data(text[start...end].utf8)) { return wrapped.texts }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
           let list = try? decoder.decode([String].self, from: Data(text[start...end].utf8)) { return list }
        throw Failure.malformedResponse
    }
}
