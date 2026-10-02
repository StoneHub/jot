import AppleFM
import Foundation

/// Image rejection can remove a request's only context. Retry with text only when that request is still grounded,
/// and tell the caller which input actually produced its result so attribution and receipts remain accurate.
public enum WindowImageGeneration {
    public enum Result: Equatable, Sendable {
        case image(String)
        case text(String)
        case needsContext

        public var usedImage: Bool { if case .image = self { return true }; return false }
        public var text: String? {
            switch self { case .image(let value), .text(let value): return value; case .needsContext: return nil }
        }
    }

    static func run(allowsTextOnly: Bool, image: @Sendable () async throws -> String,
                    text: @Sendable () async throws -> String) async throws -> Result {
        do {
            return .image(try await image())
        } catch AppleFMError.imageUnsupported, AppleFMError.unreadableImage {
            try Task.checkCancellation()
            guard allowsTextOnly else { return .needsContext }
            return .text(try await text())
        }
    }
}
