import Foundation

/// The model reported that it cannot run. `reason` is an AppleFM availability value, never model error text.
public struct ModelUnavailable: Error, Equatable {
    public let reason: String
}
