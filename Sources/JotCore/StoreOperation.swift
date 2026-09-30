import Foundation

/// The result of work already submitted to the store queue. Awaiting or cancelling
/// a caller does not alter the operation; durable saves retain their queue position.
public final class StoreOperation<Value: Sendable>: @unchecked Sendable {
    // The lock protects the result and every waiter across the store and caller queues.
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    public var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let finished = lock.withLock { () -> Result<Value, Error>? in
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let finished { continuation.resume(with: finished) }
            }
        }
    }

    func finish(_ completed: Result<Value, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            precondition(result == nil, "Store operation completed twice")
            result = completed
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(with: completed) }
    }
}
