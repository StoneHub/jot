import AppleFM
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The pinned AppleFM generic generation API. Jot owns the prompt, bounds and deadline. The terminal/editor
/// `complete` API is not used: it rejects blank input and serves a different purpose.
public enum AppleFMGeneration {
    /// Keep equal to the Package.swift pin; a test checks it.
    public static let revision = "737fac9e7147403f2777e0901f02452e8fc25ae7"
    public static let sampling = "greedy"

    public static var availability: String { AppleFMClient().modelAvailability.rawValue }

    /// Each call is a fresh AppleFM session with no retained conversation state.
    public static func generate(_ request: ModelRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                return try await AppleFMClient().generate(instructions: request.instructions, prompt: request.prompt,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maximumResponseTokens))
            } catch AppleFMError.unavailable(let availability) {
                throw ModelUnavailable(reason: availability.rawValue)
            }
        }
        #endif
        throw ModelUnavailable(reason: AppleFMAvailability.unsupportedOS.rawValue)
    }
}
