import Foundation

/// Resolves a waiting caller once when generation, cancellation and the deadline compete.
/// Callers retain ownership of model work until it actually returns.
@MainActor
final class OneShotCompletion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
