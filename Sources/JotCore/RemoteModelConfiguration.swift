import Foundation

/// Where a model outside Apple Intelligence lives: an OpenAI-compatible server, such as Ollama, LM Studio or a hosted
/// API, or Anthropic's Messages API. The key is not part of it; `ModelKeyStore` keeps that in the Keychain.
public struct RemoteModelConfiguration: Sendable, Equatable {
    public enum Format: String, Sendable, CaseIterable {
        case openAICompatible = "openai"
        case anthropic
    }

    public let format: Format
    /// The URL a request is posted to, such as `http://localhost:11434/v1/chat/completions`.
    public let requestURL: URL
    public let model: String

    /// Nil when the endpoint is not a usable URL or the model is blank. A base URL such as `…/v1` gains the format's
    /// request path. Plain HTTP is accepted only for this Mac, so a key or transcript never crosses a network unencrypted.
    public init?(format: Format, endpoint: String, model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !model.isEmpty, var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else { return nil }
        let path = format == .anthropic ? "/messages" : "/chat/completions"
        if !components.path.hasSuffix(path) { components.path += path }
        guard let url = components.url else { return nil }
        self.format = format
        self.requestURL = url
        self.model = model
    }

    /// True when requests go to a server on this Mac, such as Ollama or LM Studio.
    public var isOnDevice: Bool { requestURL.host.map(Self.isLoopback) ?? false }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
