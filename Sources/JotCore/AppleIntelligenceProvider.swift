import AppleFM
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Model, through the pinned AppleFM package. Nothing leaves the Mac.
public struct AppleIntelligenceProvider: GenerationProvider {
    public init() {}

    public var isOnDevice: Bool { true }

    public var availability: CleanupAvailability {
        switch AppleFMClient().modelAvailability {
        case .available: return .available
        case .unsupportedOS: return .olderSystem
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady, .unavailable: return .modelNotReady
        }
    }

    public func generate(_ request: ModelRequest) async throws -> String {
        try await AppleFMGeneration.generate(request)
    }

    /// Guided generation returns the list as a typed value, so the model cannot answer with malformed JSON.
    public func generateTexts(_ request: ModelRequest) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleFMClient().generate(instructions: request.instructions, prompt: request.prompt,
                generating: CleanedTranscripts.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maximumResponseTokens)).texts
        }
        #endif
        throw ModelUnavailable(reason: AppleFMAvailability.unsupportedOS.rawValue)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct CleanedTranscripts {
    var texts: [String]
}
#endif
