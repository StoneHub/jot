import Foundation

/// A language model Jot asks for text. Apple's on-device model is the default. Callers own the prompt, its bounds,
/// the deadline and the validation of what comes back, so changing the provider never changes what Jot accepts.
public protocol GenerationProvider: Sendable {
    /// Whether a request can run now. Callers check it before preparing input, so an unready provider sees nothing.
    var availability: CleanupAvailability { get }
    /// True when requests are answered on this Mac and nothing is sent over the network.
    var isOnDevice: Bool { get }
    /// Free text for one request.
    func generate(_ request: ModelRequest) async throws -> String
    /// One edited entry for each string in `request.prompt`, a JSON array, in the same order.
    func generateTexts(_ request: ModelRequest) async throws -> [String]
}
