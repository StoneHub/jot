import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Published repository information, deliberately separate from installed model provenance.
public struct ModelUpdate: Codable, Sendable, Identifiable {
    public let name: String
    public let repository: String
    public var revision: String?
    public var publishedAt: String?
    public var checkedAt: Date?
    public var changedSinceLastCheck = false
    public var error: String?
    public var id: String { repository }
    public var releasesURL: URL { URL(string: "https://huggingface.co/\(repository)/commits/main")! }
    public var summary: String {
        if let error { return "Check failed: \(error)" }
        guard let revision else { return "No update check yet." }
        let published = publishedAt.map { " · published \($0.prefix(10))" } ?? ""
        return "Published revision \(revision.prefix(8))\(published). "
            + (changedSinceLastCheck ? "Changed since your previous check. " : "")
            + "The installed cache has no recorded revision; review releases before updating."
    }
    public static var defaults: [ModelUpdate] { [
        ModelUpdate(name: "Parakeet v3 · Recognition", repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml"),
        ModelUpdate(name: "Sortformer · Speakers", repository: "FluidInference/diar-streaming-sortformer-coreml"),
        ModelUpdate(name: "Silero · Speech detection", repository: "FluidInference/silero-vad-coreml")
    ] }
    /// The models this build uses, with the last check results saved for the same repositories. A saved list from an
    /// older build must not decide which repositories are checked.
    public static func restoring(_ saved: [ModelUpdate]) -> [ModelUpdate] {
        defaults.map { model in
            guard let previous = saved.first(where: { $0.repository == model.repository }) else { return model }
            var result = model
            result.revision = previous.revision; result.publishedAt = previous.publishedAt
            result.checkedAt = previous.checkedAt; result.changedSinceLastCheck = previous.changedSinceLastCheck
            result.error = previous.error
            return result
        }
    }
    public func applying(_ data: Data, at date: Date) throws -> ModelUpdate {
        struct Published: Decodable { let sha: String; let lastModified: String? }
        let response = try JSONDecoder().decode(Published.self, from: data)
        guard response.sha.count == 40, response.sha.allSatisfy({ $0.isHexDigit }) else {
            throw URLError(.cannotParseResponse)
        }
        var result = self
        result.changedSinceLastCheck = revision.map { $0 != response.sha } ?? false
        result.revision = response.sha; result.publishedAt = response.lastModified
        result.checkedAt = date; result.error = nil
        return result
    }
    public func check() async -> ModelUpdate {
        do {
            var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(repository)")!)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try applying(data, at: Date())
        } catch {
            var result = self; result.error = error.localizedDescription
            return result
        }
    }
}
