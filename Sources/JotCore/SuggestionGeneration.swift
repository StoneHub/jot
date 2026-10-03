import AppleFM
import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The pinned AppleFM generic generation API. Jot owns the prompt, bounds and deadline. The terminal/editor
/// `complete` API is not used: it rejects blank input and serves a different purpose.
public enum AppleFMGeneration {
    /// Keep equal to the Package.swift pin; a test checks it.
    public static let revision = "5b937241b0236f892af28588e75a78dd557acf21"
    public static let sampling = "greedy"

    public static var availability: String { AppleFMClient().modelAvailability.rawValue }

    /// "available" when the model is ready and takes an image with the prompt; otherwise why not, as an AppleFM value.
    /// Checked before a window is captured, so an unsupported Mac never takes a screenshot.
    public static var imageAvailability: String {
        let client = AppleFMClient()
        guard client.modelAvailability == .available else { return client.modelAvailability.rawValue }
        let support = client.imageSupport
        return support == .supported ? AppleFMAvailability.available.rawValue : support.rawValue
    }

    public static var acceptsImages: Bool { imageAvailability == AppleFMAvailability.available.rawValue }

    /// Each call is a fresh AppleFM session with no retained conversation state.
    public static func generate(_ request: ModelRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                return try await AppleFMClient().generate(instructions: request.instructions, prompt: request.prompt,
                    options: options(for: request))
            } catch AppleFMError.unavailable(let availability) {
                throw ModelUnavailable(reason: availability.rawValue)
            }
        }
        #endif
        throw ModelUnavailable(reason: AppleFMAvailability.unsupportedOS.rawValue)
    }

    /// The same request with one image of the window around the field. The image is used for this call only. When the
    /// model turns the image down, a grounded `textOnly` request can run within the same deadline; the result reports it.
    public static func generate(_ request: ModelRequest, image: CGImage, textOnly: ModelRequest,
                                allowsTextOnly: Bool, onImageRejected: @Sendable () async -> Void) async throws -> WindowImageGeneration.Result {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                return try await WindowImageGeneration.run(allowsTextOnly: allowsTextOnly, onRejected: onImageRejected, image: {
                    try await AppleFMClient().generate(instructions: request.instructions, prompt: request.prompt,
                        image: .cgImage(image), options: options(for: request))
                }, text: { try await generate(textOnly) })
            } catch AppleFMError.unavailable(let availability) {
                throw ModelUnavailable(reason: availability.rawValue)
            }
        }
        #endif
        throw ModelUnavailable(reason: AppleFMAvailability.unsupportedOS.rawValue)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func options(for request: ModelRequest) -> GenerationOptions {
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maximumResponseTokens)
    }
    #endif
}
